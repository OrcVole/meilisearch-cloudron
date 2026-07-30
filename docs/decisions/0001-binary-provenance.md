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

## History

**2026-07-30, Dockerfile phase.** Status moves from accepted-unexercised to accepted-and-built.
Three things this record assumed turned out to need correction or confirmation.

- **The release binary is fine on this base, as hoped.** `meilisearch-linux-amd64` for 1.51.0 is a
  dynamically linked glibc executable whose highest required symbol version is `GLIBC_2.35`,
  against the base image's 2.39. The build-time gate runs `file`, `ldd`, a grep for `not found`,
  and `--version`, and it passes. The musl fallback for the server binary was therefore not
  needed, and is not in the Dockerfile.
- **Upstream publishes no checksum file with the release.** There is no `.sha256`, no
  `SHASUMS` asset, and no checksum in the release notes. The sha256 pinned in the Dockerfile,
  `73f4f8809a80c5293a594de100b6121cb60879f9869875bdbc732c03771de560`, is taken from the `digest`
  field of the asset object in the GitHub releases API response for the `v1.51.0` tag, and was
  independently confirmed by running `sha256sum` over the downloaded file. Verified negatively as
  well: building with a deliberately wrong value fails the build at `sha256sum -c` rather than
  proceeding.
- **`meilitool` is not a release asset, and it is NOT statically linked.** This record assumed the
  official Docker image was musl **static**. It is not. `file` reports
  `ELF 64-bit LSB pie executable, x86-64, dynamically linked, interpreter
  /lib/ld-musl-x86_64.so.1`, and it needs `libc.musl-x86_64.so.1` and a musl-built
  `libgcc_s.so.1`, none of which exist on a glibc Ubuntu base. Copying the binary alone would have
  produced a tool that fails to execute the moment an operator reaches for it, most likely during
  an incident.

  The fix keeps the musl userland strictly quarantined: the loader and `libgcc_s.so.1` are copied
  into `/app/code/musl/`, never into a system library path, and `/app/code/meilitool` is a small
  wrapper that invokes the musl loader explicitly with `--library-path /app/code/musl`. Nothing
  from the base image can pick up a musl library by accident, and the build gate proves the
  arrangement works by running `/app/code/meilitool --version` at build time. Installing Ubuntu's
  `musl` package instead was rejected because it would put a musl loader on a system path and add
  an `apt` step to an otherwise fully digest-pinned build.
