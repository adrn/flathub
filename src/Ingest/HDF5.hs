{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module Ingest.HDF5
  ( ingestHDF5
  ) where

import           Control.Exception (bracket, handleJust)
import           Control.Monad (foldM, guard, when, unless)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Control (liftBaseOp)
import qualified Bindings.HDF5 as H5
import qualified Bindings.HDF5.Error as H5E
import qualified Bindings.HDF5.ErrorCodes as H5E
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as BSC
import           Data.Foldable (fold)
import           Data.List (find, nub)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Data.Proxy (Proxy(Proxy))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as VSM
import           Data.Word (Word64, Word8)
import           System.IO (hFlush, stdout)

import Field
import Catalog
import Global
import qualified ES
import Ingest.Types

type DataBlock = [(T.Text, TypeValue V.Vector)]

attributePrefix :: T.Text
attributePrefix = "_attribute:"

optionalPrefix :: T.Text
optionalPrefix = "_optional:"

hdf5ReadVector :: H5.NativeType a => H5.Dataset -> [H5.HSize] -> Word64 -> IO (V.Vector a)
hdf5ReadVector d o l = do
  v <- bracket (H5.getDatasetSpace d) H5.closeDataspace $ \s -> do
    (b@(b1:_), _) <- H5.getSimpleDataspaceExtent s
    let o1:os = pad o b
        l' | o1 >= b1 = 0
           | otherwise = min (fromIntegral l) $ b1 - o1
    v <- VSM.unsafeNew (fromIntegral l')
    when (l' > 0) $ do
      H5.selectHyperslab s H5.Set ((o1, Nothing, l', Nothing) : map (, Nothing, 1, Nothing) os)
      bracket (H5.createSimpleDataspace [l']) H5.closeDataspace $ \m ->
        H5.readDatasetInto d (Just m) (Just s) Nothing v
    V.convert <$> VS.unsafeFreeze v
  t <- H5.getDatasetType d
  tc <- H5.getTypeClass t
  ts <- H5.getTypeSize t
  let nt = H5.nativeTypeOf1 v
  ntc <- H5.getTypeClass nt
  nts <- H5.getTypeSize nt
  unless (tc == ntc && ts >= nts) $ fail $ "HDF5 type mismatch: " ++ show ((tc, ts), (ntc, nts))
  return v
  where
  pad s [] = s
  pad (x:s) (_:n) = x : pad s n
  pad    s  (_:n) = 0 : pad s n -- replicate n 0

toBool :: Word8 -> Bool
toBool = (0 /=)

hdf5ReadType :: Functor f => Type -> (forall a . H5.NativeType a => IO (f a)) -> IO (TypeValue f)
hdf5ReadType (Long    _) f = Long    <$> f
hdf5ReadType (Integer _) f = Integer <$> f
hdf5ReadType (Short   _) f = Short   <$> f
hdf5ReadType (Byte    _) f = Byte    <$> f
hdf5ReadType (Double  _) f = Double  <$> f
hdf5ReadType (Float   _) f = Float   <$> f
hdf5ReadType (Boolean _) f = Boolean . fmap toBool <$> f
hdf5ReadType t           _ = fail $ "Unsupported HDF5 type: " ++ show t

loadBlock :: Ingest -> H5.File -> IO DataBlock
loadBlock info@Ingest{ ingestCatalog = Catalog{ catalogFieldGroups = cat }, ingestOffset = off } hf = concat <$> mapM loadf cat where
  loadf f = case fromMaybe (fieldName f) $ fieldIngest f of
    "" -> concat <$> mapM (loadf . mappend f) (fold $ fieldSub f)
    n | attributePrefix `T.isPrefixOf` n -> return []
    (T.stripPrefix optionalPrefix -> Just n) ->
      handleJust
        (\(H5E.errorStack -> (H5E.HDF5Error{ H5E.classId = cls, H5E.majorNum = Just H5E.Sym, H5E.minorNum = Just H5E.NotFound }:_)) -> guard (cls == H5E.hdfError))
        (\() -> return [])
      $ loadf f{ fieldIngest = Just n }
    n | "_illustris:" `T.isPrefixOf` n ->
      return [(fieldName f, Long (V.generate (fromIntegral $ maybe id (min . subtract off) (ingestSize info) $ ingestBlockSize info) ((+) (fromIntegral $ ingestStart info + off) . fromIntegral)))]
    n -> bracket (H5.openDataset hf (TE.encodeUtf8 n) Nothing) H5.closeDataset $ \hd -> do
      let
        loop _ [] = return []
        loop i (f':fs') = do
          x <- hdf5ReadType (fieldType f') $ hdf5ReadVector hd (fromIntegral off : if i == 0 then [] else [i]) $ ingestBlockSize info
          ((fieldName f', x) :) <$> loop (succ i) fs'
      loop 0 $ expandFields (V.singleton f)

ingestBlock :: Ingest -> DataBlock -> M Int
ingestBlock info@Ingest{ ingestCatalog = cat@Catalog{ catalogStore = ~CatalogES{} }, ingestOffset = off } dat = do
  n <- case nub $ map (unTypeValue V.length . snd) dat of
    [n] -> return n
    n -> fail $ "Inconsistent data length: " ++ show n
  when (n /= 0) $ ES.createBulk cat $ map doc [0..pred n]
  return n
  where
  doc i =
    ( ingestPrefix info ++ show (ingestStart info + off + fromIntegral i)
    , ingestJConsts info <> foldMap (\(k, v) -> k J..= fmapTypeValue1 (V.! i) v) dat)

withHDF5 :: FilePath -> (H5.File -> IO a) -> IO a
withHDF5 fn = bracket (H5.openFile (BSC.pack fn) [H5.ReadOnly] Nothing) H5.closeFile

withAttribute :: H5.File -> BSC.ByteString -> (H5.Attribute -> IO a) -> IO a
withAttribute hf p = bracket
  (if BSC.null g then H5.openAttribute hf a else bracket
    (H5.openGroup hf g Nothing)
    H5.closeGroup $ \hg -> H5.openAttribute hg a)
  H5.closeAttribute
  where (g, a) = BSC.breakEnd ('/'==) p

readAttribute :: H5.File -> BSC.ByteString -> Type -> IO (TypeValue V.Vector)
readAttribute hf p t = withAttribute hf p $ \a ->
  hdf5ReadType t $ VS.convert <$> H5.readAttribute a

readScalarAttribute :: H5.File -> BSC.ByteString -> Type -> IO Value
readScalarAttribute hf p t = do
  r <- readAttribute hf p t
  let l = unTypeValue V.length r
  unless (l == 1) $ fail ("attribute " ++ show p ++ ": expected scalar, got " ++ show l)
  return $ fmapTypeValue1 V.head r

ingestHFile :: Ingest -> H5.File -> M Word64
ingestHFile info hf = do
  info' <- foldM infof info (catalogFieldGroups $ ingestCatalog info)
  if ingestSize info' == Just 0 -- for illustris, if there's no data, don't try reading (since datasets are missing)
    then return 0
    else loop info'
  where
  infof i f@Field{ fieldIngest = (>>= T.stripPrefix attributePrefix) -> Just n } = liftIO $ do
    v <- readScalarAttribute hf (TE.encodeUtf8 n) (fieldType f)
    return i{ ingestConsts = f{ fieldType = v, fieldSub = Proxy } : ingestConsts i }
  infof i Field{ fieldIngest = (>>= T.stripPrefix "_illustris:") -> Just ill } = liftIO $ do
    Long sz <- readScalarAttribute hf ("Header/N" <> case ill of { "Subhalo" -> "subgroup" ; s -> TE.encodeUtf8 (T.toLower s) } <> "s_ThisFile") (Long Proxy)
    handleJust
      (\(H5E.errorStack -> (H5E.HDF5Error{ H5E.classId = cls, H5E.majorNum = Just H5E.Attr, H5E.minorNum = Just H5E.NotFound }:_)) -> guard (cls == H5E.hdfError)) return $ do
        Long fi <- readScalarAttribute hf "Header/Num_ThisFile" (Long Proxy)
        Long ids <- readAttribute hf ("Header/FileOffsets_" <> TE.encodeUtf8 ill) (Long Proxy)
        let si = fromIntegral (ids V.! fromIntegral fi)
        unless (si == ingestStart i) $ fail "start offset mismatch"
    si <- constv "simulation" i
    sn <- constv "snapshot" i
    return i
      { ingestPrefix = si ++ '_' : sn ++ "_"
      , ingestSize = Just (fromIntegral sz) }
  infof i _ = return i
  constv f = maybe (fail $ "const field " ++ show f ++ " not fonud")
    (return . show . fieldType)
    . find ((f ==) . fieldName) . ingestConsts
  loop i = do
    liftIO $ putStr (show (ingestOffset i) ++ "\r") >> hFlush stdout
    n <- ingestBlock i =<< liftIO (loadBlock i hf)
    let i' = i{ ingestOffset = ingestOffset i + fromIntegral n }
    if n < fromIntegral (ingestBlockSize i)
      then do
        unless (all (ingestOffset i' ==) $ ingestSize i') $ fail $ "size mismatch: expected " ++ show (ingestSize i') ++ " rows, got " ++ show (ingestOffset i')
        return $ ingestOffset i'
      else loop i'

ingestHDF5 :: Ingest -> M Word64
ingestHDF5 info = liftBaseOp (withHDF5 $ ingestFile info) $ ingestHFile info
