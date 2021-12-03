FROM fpco/stack-build-small:lts-18.18
ADD https://deb.nodesource.com/gpgkey/nodesource.gpg.key /tmp/
RUN apt-key add /tmp/nodesource.gpg.key && \
    echo deb https://deb.nodesource.com/node_12.x bionic main > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y libhdf5-dev libbz2-dev pkg-config nodejs && \
    rm -rf /var/lib/apt/lists/*
RUN echo /opt/ghc/*/lib/ghc-*/rts > /etc/ld.so.conf.d/ghc.conf && \
    ldconfig
RUN useradd -u 999 -m flathub
USER flathub

EXPOSE 8092
ENTRYPOINT ["/home/flathub/.local/bin/flathub"]
CMD []
ENV LD_LIBRARY_PATH=/home/stackage/.stack/programs/x86_64-linux/ghc-8.10.6/lib/ghc-8.10.6/rts

COPY --chown=flathub stack.yaml *.cabal Setup.hs COPYING /home/flathub/flathub/
WORKDIR /home/flathub/flathub
RUN stack build --dependencies-only --extra-include-dirs=/usr/include/hdf5/serial --extra-lib-dirs=/usr/lib/x86_64-linux-gnu/hdf5/serial
COPY --chown=flathub src ./src
RUN stack install && rm -rf .stack-work
COPY --chown=flathub web ./web
RUN make -C web
COPY --chown=flathub html ./html
COPY --chown=flathub config ./config
COPY --chown=flathub catalogs ./catalogs
