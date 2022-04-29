{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Api
  ( apiTop
  , apiCatalog
  , apiStats
  , openApi
  ) where

import           Control.Lens ((&), (&~), (.~), (?~), over)
import           Control.Monad.Reader (asks)
import           Control.Monad.Trans.State (modify)
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.HashMap.Strict as HM
import           Data.Maybe (fromJust, isJust)
import qualified Data.OpenApi as OA
import qualified Data.OpenApi.Declare as OAD
import           Data.Proxy (Proxy(Proxy))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import           Data.Version (showVersion)
import           Network.HTTP.Types.Status (badRequest400)
import qualified Network.Wai as Wai
import           Waimwork.Response (okResponse, response)
import           Waimwork.Result (result)
import qualified Web.Route.Invertible as R
import qualified Web.Route.Invertible.Internal as RI
import qualified Web.Route.Invertible.Wai as R

import qualified Paths_flathub as Paths
import Monoid
import Type
import Field
import Catalog
import Global
import OpenApi
import Backend

apiBase :: R.Path ()
apiBase = "api"

-------- /api

catalogJSON :: Catalog -> J.Series
catalogJSON Catalog{..} =
     "name" J..= catalogName
  <> "order" J..= catalogOrder
  <> "title" J..= catalogTitle
  <> "synopsis" J..= catalogSynopsis

instance OA.ToSchema Catalog where
  declareNamedSchema _ = do
    return $ OA.NamedSchema (Just "CatalogMeta") $ objectSchema
      "High-level metadata for a dataset catalog"
      [ ("name", schemaDescOf catalogName "globally unique catalog id used in urls", True)
      , ("order", schemaDescOf catalogOrder "sort key for display order", True)
      , ("title", schemaDescOf catalogTitle "display name", True)
      , ("synopsis", schemaDescOf catalogSynopsis "short description", True)
      ]

apiTop :: Route ()
apiTop = getPath apiBase $ \() _ -> do
  cats <- asks globalCatalogs
  return $ okResponse [] $ JE.list (J.pairs . catalogJSON) $ filter catalogVisible $ HM.elems $ catalogMap cats

-------- /api/{catalog}

fieldsJSON :: FieldGroup -> FieldGroups -> J.Encoding
fieldsJSON b = JE.list fieldJSON . V.toList where
  fieldJSON f@Field{ fieldName = name, ..} = J.pairs
    $  "key" J..= name
    <> "name" J..= fieldName bf
    <> "title" J..= fieldTitle
    <> "descr" J..= fieldDescr
    <> "type" J..= fieldType
    <> "base" J..= baseType ('f','i','b','s','v') fieldType
    <> foldMap ("enum" J..=) fieldEnum
    <> mwhen (fieldDisp f) ("disp" J..= True)
    <> foldMap ("units" J..=) fieldUnits
    <> foldMap ("required" J..=) (case fieldFlag of
        FieldTop -> Just False
        FieldRequired -> Just True
        _ -> Nothing)
    <> mwhen fieldTerms ("terms" J..= fieldTerms)
    <> mwhen fieldWildcard ("wildcard" J..= fieldWildcard)
    <> foldMap ("dict" J..=) fieldDict
    <> foldMap ("scale" J..=) fieldScale
    <> mwhen fieldReversed ("reversed" J..= fieldReversed)
    <> mwhen (isJust fieldAttachment) ("attachment" J..= True)
    <> foldMap (JE.pair "sub" . fieldsJSON bf) fieldSub
    where
    bf = b <> f

instance OA.ToSchema Type where
  declareNamedSchema _ = do
    return $ OA.NamedSchema (Just "Type") $ mempty
      & OA.description ?~ "storage type"
      & OA.type_ ?~ OA.OpenApiString
      & OA.enum_ ?~ map J.toJSON allTypes

instance OA.ToSchema FieldGroup where
  declareNamedSchema t = do
    ref <- OA.declareSchemaRef t
    return $ OA.NamedSchema (Just "FieldGroup") $ objectSchema
      "A single field within a catalog, or a hiearchical group of fields"
      [ ("key", schemaDescOf fieldName "local name of field within this group", True)
      , ("name", schemaDescOf fieldName "global unique (\"variable\") name of field within the catalog", True)
      , ("title", schemaDescOf fieldTitle "display name of the field within the group", True)
      , ("descr", schemaDescOf (fromJust . fieldDescr) "description of field within the group", False)
      , ("type", schemaDescOf typeOfValue "raw storage type", True)
      , ("base", OA.Inline $ mempty
          & OA.description ?~ "base storage type (floating, integral, boolean, string, void)"
          & OA.type_ ?~ OA.OpenApiString
          & OA.enum_ ?~ map J.toJSON "fibsv"
          , True)
      , ("enum", schemaDescOf (fromJust . fieldEnum) "if present, display values as these keywords instead (integral or boolean: enum[<int>value])", False)
      , ("disp", schemaDescOf fieldDisp "include field in data display by default", False)
      , ("units", schemaDescOf (fromJust . fieldUnits) "display units", False)
      , ("required", schemaDescOf (True ==) "true = required filter; false = top-level (default) optional filter; missing = normal", False)
      , ("terms", schemaDescOf fieldTerms "display dynamically as a dropdown of values", False)
      , ("dict", schemaDescOf (fromJust . fieldDict) "unique key index to global field dictionary (for compare)", False)
      , ("scale", schemaDescOf (fromJust . fieldScale) "scale factor to dict-comparable units, display  value*scale (for compare)", False)
      , ("reversed", schemaDescOf fieldReversed "display axes and ranges in reverse (high-low)", False)
      , ("attachment", schemaDescOf isJust "this is a meta field for a downloadable attachment (type boolean, indicating presence)", False)
      , ("wildcard", schemaDescOf fieldWildcard "allow wildcard prefix searching on keyword field (\"xy*\")", False)
      , ("sub", OA.Inline $ arraySchema ref
          & OA.description ?~ "child fields: if this is present, this is a pseudo grouping field which does not exist itself, but its properties apply to its children"
          , False)
      ]

catalogSchema :: OAD.Declare (OA.Definitions OA.Schema) OA.Schema
catalogSchema = do
  fdef <- OA.declareSchemaRef (Proxy :: Proxy FieldGroup)
  return $ objectSchema
    "Full catalog metadata"
    [ ("fields", OA.Inline $ arraySchema fdef
      & OA.description ?~ "field groups"
      , True)
    , ("count", schemaDescOf (fromJust . catalogCount) "total number of rows (if known)", False)
    , ("sort", schemaDescOf catalogSort "default sort fields", False)
    ]

catalogBase :: R.Path Simulation
catalogBase = apiBase R.*< R.parameter

apiCatalog :: Route Simulation
apiCatalog = getPath catalogBase $ \sim _ -> do
  cat <- askCatalog sim
  return $ okResponse [] $ J.pairs
    $ catalogJSON cat
    <> JE.pair "fields" (fieldsJSON mempty $ catalogFieldGroups cat)
    <> foldMap ("count" J..=) (catalogCount cat)
    <> mwhen (not $ null $ catalogSort cat)
      ("sort" J..= catalogSort cat)

-------- /api/{catalog}/stats

instance OA.ToSchema FieldValue where
  declareNamedSchema _ = do
    return $ OA.NamedSchema (Just "FieldValue") $ mempty
      & OA.description ?~ "a value for a field, which must match the type of the field"
      & OA.anyOf ?~ map (\t -> unTypeValue (\p -> OA.Inline $ OA.toSchema p & OA.title ?~ T.pack (show t)) t) allTypes

instance Typed a => J.FromJSON (FieldFilter a) where
  parseJSON j@(J.Array _) = FieldEQ <$> J.parseJSON j
  parseJSON (J.Object o) = FieldRange
    <$> o J..:? "gte"
    <*> o J..:? "lte"
  parseJSON j = FieldEQ . return <$> J.parseJSON j

instance Typed a => OA.ToSchema (FieldFilter a) where
  declareNamedSchema _ = do
    fv <- OA.declareSchemaRef (Proxy :: Proxy FieldValue)
    return $ OA.NamedSchema Nothing $ mempty
      & OA.description ?~ "filter for a named field to be equal to a specific value or match other contraints"
      & OA.anyOf ?~
        [ fv
        , OA.Inline $ arraySchema fv & OA.description ?~ "equal to any of these values"
        , OA.Inline $ objectSchema "in a bounded range: >= gte and <= lte, either of which may be omitted"
          [ ("gte", fv, False)
          , ("lte", fv, False)
          ]
        ]

instance OA.ToSchema Filters where
  declareNamedSchema _ = do
    ff <- OA.declareSchemaRef (Proxy :: Proxy (FieldFilter ()))
    return $ OA.NamedSchema (Just "Filters") $ objectSchema
      "filters to apply to a query"
      [ ("sample", OA.Inline $ OA.toSchema (proxyOf $ filterSample undefined)
        & OA.description ?~ "randomly select a fractional sample"
        & OA.default_ ?~ J.Number 1
        & OA.minimum_ ?~ 0
        & OA.exclusiveMinimum ?~ True
        & OA.maximum_ ?~ 1
        & OA.exclusiveMaximum ?~ False
        , False)
      , ("seed", OA.Inline $ OA.toSchema (proxyOf $ fromJust $ filterSeed undefined)
        & OA.description ?~ "seed for random sample selection (defaults to new random seed)"
        , False)
      ]
      & OA.additionalProperties ?~ OA.AdditionalPropertiesSchema ff

listParam :: Wai.Request -> BS.ByteString -> [BS.ByteString]
listParam req param = foldMap sel $ Wai.queryString req where
  sel (p, v)
    | p == param = foldMap (filter (not . BSC.null) . BSC.splitWith delim) v
    | otherwise = []
  delim ',' = True
  delim ' ' = True
  delim _ = False

lookupField :: Catalog -> BS.ByteString -> M Field
lookupField cat n =
  maybe (result $ response badRequest400 [] $ "Field not found: " <> n) return
  $ do
  n' <- either (const Nothing) Just $ TE.decodeUtf8' n
  HM.lookup n' $ catalogFieldMap cat

fieldsParam :: Catalog -> Wai.Request -> BS.ByteString -> M [Field]
fieldsParam cat req param = mapM (lookupField cat) $ listParam req param

apiStats :: Route Simulation
apiStats = getPath (catalogBase R.>* "stats") $ \sim req -> do
  cat <- askCatalog sim
  fields <- fieldsParam cat req "fields"
  return $ okResponse [] $ J.foldable $ map fieldName fields

  -- gte[field]=3&lte[field]=5&eq[field]=2&wildcard[field]=

-------- /openapi.json

openApi :: Route ()
openApi = getPath "openapi.json" $ \() req ->
  return $ okResponse [] $ J.encode $ mempty &~ do
    modify
      $ (over OA.info
        $ (OA.title .~ "FlatHUB API")
        . (OA.version .~ T.pack (showVersion Paths.version)))
      . (OA.servers .~
        [ OA.Server (urltext $ baseapi $ R.waiRequest req) Nothing mempty
        , OA.Server (urltext $ baseapi produrl) (Just "production") mempty
        ])

    catmeta <- stateDeclareSchema $ OA.declareSchemaRef (Proxy :: Proxy Catalog)
    catschema <- stateDeclareSchema catalogSchema
    filters <- stateDeclareSchema $ OA.declareSchemaRef (Proxy :: Proxy Filters)
    filterp <- define "filter" $ mempty
      & OA.name .~ "filter"
      & OA.in_ .~ OA.ParamQuery
      & OA.style ?~ OA.StyleDeepObject
      & OA.schema ?~ filters

    fieldsp <- define "fields" $ mempty
      & OA.name .~ "fields"
      & OA.description ?~ "list of fields to return"
      & OA.in_ .~ OA.ParamQuery
      & OA.style ?~ OA.StyleForm
      & OA.explode ?~ False
      & OA.schema ?~ OA.Inline (arraySchema $ schemaDescOf T.pack "field name in catalog")

    path apiTop () [] $ jsonOp "top"
      "Get the list of available dataset catalogs"
      "list of catalogs"
      (mempty
        & OA.type_ ?~ OA.OpenApiArray
        & OA.items ?~ OA.OpenApiItemsObject catmeta)

    path apiCatalog "sim" [simparam] $ jsonOp "catalog"
      "Get full metadata about a specific catalog"
      "catalog metadata"
      (mempty
        & OA.allOf ?~
          [ catmeta
          , OA.Inline catschema
          ])

    path apiStats "sim" [simparam] $ jsonOp "stats"
      "Get statistics about fields (given some filters)"
      "field statistics"
      mempty
      & OA.parameters .~ [filterp, fieldsp]
  where
  baseapi = RI.requestRoute' (R.routePath apiBase) ()
  produrl = mempty{ R.requestSecure = True, R.requestHost = RI.splitHost "flathub.flatironinstitute.org" }
  urltext = requestUrl
  path = routeOperation (baseapi RI.blankRequest)
  simparam = mempty
    & OA.name .~ "sim"
    & OA.schema ?~ schemaDescOf T.pack "catalog id"
