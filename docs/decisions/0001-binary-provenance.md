# 0001: Official release binary on pinned cloudron/base, no compilation from source

Status: accepted (build not yet exercised; verify at the Dockerfile phase)

## Context

Meilisearch publishes two binary shapes: official GitHub release binaries per platform, and an
official Docker image (`getmeili/meilisearch:v{VERSION}`) built on Alpine and therefore statically
linked against musl. The Cloudron base image, `cloudron/base:5.0.0`, is Ubuntu 24.04 with glibc
2.39. The packaging skill's standing rule is a pinned `cloudron/base` final stage, because the
dashboard file manager, web terminal, and log viewer in the Cloudron platform depend on its
userland; compiling Meilisearch from source would add a large, slow, and needlessly novel build
surface for a project that already publishes verifiable release artefacts.

## Decision

Final image stage is `cloudron/base:5.0.0`, pinned by digest (the exact digest is recorded in the
Dockerfile once it exists, taken from the current packaging skill reference, not from memory). A
build stage fetches the official GitHub release glibc binary for x86_64 at `1.51.0`, verifies it
against its published sha256, and copies it onto the base. A build-time `ldd` check must resolve
every dynamic symbol against the base image's glibc (2.39 on the base, >= 2.35 required by the
release binary); an unresolved symbol fails the build rather than surfacing as a runtime crash.
`meilitool` is installed the same way if the release ships it as an asset; otherwise it is
extracted from the official Docker image in a separate build stage, which is musl static, so its
presence in the final image is independent of the server binary's linkage. If the glibc release
binary fails the `ldd` gate at build time, the fallback is the musl-linked binary extracted from
the official Docker image, verified with `file` rather than assumed. No component in this package
is compiled from source.

## Consequences

- The upstream version lives in exactly one canonical build argument once the Dockerfile exists;
  nothing else hardcodes it, and the manifest's `upstreamVersion` mirrors it by convention, not by
  automatic derivation.
- A future glibc floor bump in an upstream release fails the build loudly, at build time, rather
  than producing a binary that crashes on first exec inside a running container.
- This decision is unexercised at the scaffold phase: no Dockerfile exists yet, so the `ldd` gate,
  the sha256 verification, and the musl fallback are all to be proven, not assumed, once the
  Dockerfile is written. Record the outcome in `docs/PACKAGING-NOTES.md` when it is.
