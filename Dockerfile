# Meilisearch packaged for Cloudron.
#
# The single source of truth for the upstream version is the MEILISEARCH_VERSION build argument
# below. The Cloudron manifest mirrors it in `upstreamVersion`; nothing else hardcodes it.
# See docs/decisions/0001-binary-provenance.md for why nothing here is compiled from source.
#
# Two upstream artefacts are used, and they are NOT the same build:
#
#   * `meilisearch` comes from the official GitHub release asset `meilisearch-linux-amd64`, which
#     is a glibc-linked dynamic executable requiring at most GLIBC_2.35. cloudron/base:5.0.0 is
#     Ubuntu 24.04 with glibc 2.39, which satisfies it. The linkage gate below fails the BUILD if
#     that ever stops being true, rather than letting it surface as a runtime crash.
#   * `meilitool` is not published as a release asset at all, so it is taken from the official
#     Alpine image. It is musl-linked and, contrary to the assumption recorded in ADR 0001, it is
#     NOT statically linked: it needs the musl loader and libgcc_s. Those two libraries are
#     carried alongside it under /app/code/musl and reached through an explicit loader
#     invocation, so no musl library is ever installed into a system path where a glibc binary
#     from the base image could pick it up. See the History note in ADR 0001.

ARG MEILISEARCH_VERSION=1.53.1

# --- Stage 1: the official upstream image, used only as a source for meilitool and musl ------
# Pinned by digest (resolved 2026-07-30). Tag v1.51.0 resolves to this multi-architecture index.
FROM docker.io/getmeili/meilisearch:v1.53.1@sha256:8d6643d86d71fad6ad3cba92cde7ccfce9e4d6c384bda67598eb553571c32431 AS upstream

# --- Stage 2: fetch and verify the official release binary ----------------------------------
# Built on the same base as the final stage so the build needs no third image.
FROM docker.io/cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c AS fetch

ARG MEILISEARCH_VERSION
# sha256 of meilisearch-linux-amd64 for v1.52.0, taken from the `digest` field of the GitHub
# releases API asset object (api.github.com/repos/meilisearch/meilisearch/releases/tags/v1.52.0)
# on 2026-08-03; the build's own `sha256sum -c` below re-verifies it over the downloaded file.
# Upstream publishes no separate checksum file with the release.
ARG MEILISEARCH_SHA256=cd8e446b29cefe44cdbc872ffb2de906ada165f4b96a33bb9e1a706b1e9279a0

RUN set -eux; \
    curl -fsSL -o /tmp/meilisearch \
      "https://github.com/meilisearch/meilisearch/releases/download/v${MEILISEARCH_VERSION}/meilisearch-linux-amd64"; \
    echo "${MEILISEARCH_SHA256}  /tmp/meilisearch" | sha256sum -c -; \
    chmod 0755 /tmp/meilisearch

# --- Stage 3: the Cloudron app image ---------------------------------------------------------
# The final stage must be this exact base so the Cloudron file manager, web terminal, and log
# viewer work. Tag 5.0.0 resolves to this digest (Ubuntu 24.04, glibc 2.39).
FROM docker.io/cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# cloudron/base:5.0.0 already provides gosu, curl, jq, openssl, file, and coreutils, which is
# everything the entrypoint and the backup script need. Nothing is installed with apt, so the
# build is reproducible from the three pinned digests above and one pinned sha256.

RUN mkdir -p /app/code/musl

# The search server itself: the verified glibc release binary.
COPY --from=fetch /tmp/meilisearch /app/code/meilisearch

# The offline maintenance tool, plus the musl loader and libgcc it needs. These live in their own
# directory and are never placed on a system library path.
COPY --from=upstream /bin/meilitool /app/code/meilitool.bin
COPY --from=upstream /lib/ld-musl-x86_64.so.1 /app/code/musl/ld-musl-x86_64.so.1
COPY --from=upstream /usr/lib/libgcc_s.so.1 /app/code/musl/libgcc_s.so.1

# Package scripts.
COPY start.sh /app/code/start.sh
COPY backup-snapshot.sh /app/code/backup-snapshot.sh
COPY meilitool /app/code/meilitool

RUN set -eux; \
    ln -sf ld-musl-x86_64.so.1 /app/code/musl/libc.musl-x86_64.so.1; \
    chmod 0755 /app/code/meilisearch /app/code/meilitool.bin /app/code/meilitool \
               /app/code/start.sh /app/code/backup-snapshot.sh

# Record the pinned upstream version in the image, for log output and for the boot-time version
# marker that the restore decision tree in ADR 0005 compares against.
ARG MEILISEARCH_VERSION
ENV MEILISEARCH_VERSION=${MEILISEARCH_VERSION}

# Linkage gate: fail the BUILD if either binary cannot resolve its libraries on this base, or if
# either one does not execute and report the expected version. This is the gate ADR 0001 calls
# for. It passes on base 5.0.0 (glibc 2.39, binary needs at most GLIBC_2.35), and it guards
# against a future base downgrade or an upstream toolchain bump that raises the glibc floor.
RUN set -eux; \
    file /app/code/meilisearch; \
    ldd /app/code/meilisearch; \
    if ldd /app/code/meilisearch 2>&1 | grep -qE 'not found'; then \
      echo "FATAL: meilisearch has an unresolved shared library or glibc symbol on this base"; \
      exit 1; \
    fi; \
    /app/code/meilisearch --version | grep -qF "meilisearch ${MEILISEARCH_VERSION}"; \
    file /app/code/meilitool.bin; \
    /app/code/meilitool --version | grep -qF "meilitool ${MEILISEARCH_VERSION}"; \
    echo "linkage gate passed for ${MEILISEARCH_VERSION}"

LABEL org.opencontainers.image.title="meilisearch-cloudron" \
      org.opencontainers.image.description="Meilisearch search engine packaged for Cloudron" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /app/code

# start.sh runs as root, prepares /app/data and /app/db, then drops to the cloudron user via
# gosu. Never ENTRYPOINT: the platform runs the backup command as an explicit command in a
# temporary container, and an ENTRYPOINT would prepend the server to it.
CMD [ "/app/code/start.sh" ]
