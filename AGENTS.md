# AGENTS.md: Meilisearch Cloudron package working contract

The settled-decisions record for packaging **Meilisearch** (`meilisearch`, MIT AND BUSL-1.1) as a
Cloudron community app. Read this before changing anything. Do not relitigate these decisions
without a concrete reason found on a running box. **The box is the authority, not the docs.**

## What this package is

Meilisearch is a typo-tolerant, open source search engine written in Rust, packaged here as a
headless search API. The package runs the MIT-licensed community engine only; no Business Source
License 1.1 enterprise edition feature is enabled.

Topology, one process, logging to stdout:

| Process | Role | Port (localhost unless noted) |
|---|---|---|
| meilisearch | Search API, production mode | 7700 (Cloudron `httpPort`) |

State: the Meilisearch data store (`data.ms`) lives on the Cloudron `persistentDirs` path
`/app/db`, kept out of the ordinary backup file walk because it churns constantly under indexing.
The master key, retained snapshots, retained dumps, and any operator overrides live under the
ordinary `localstorage` addon path `/app/data`. No other upstream component is bundled; there is no
dashboard, no supervisor, and no bundled reverse proxy.

## Golden rules

1. **Conformance to the Cloudron contract first.** Adapt the application's runtime environment
   only. Never patch the application itself.
2. **Pin everything by digest**: the base image and the upstream binary. Exactly one canonical
   place records the upstream version, mirrored in the manifest as `upstreamVersion`.
3. **Persisted state only in `/app/data` and `/app/db`.** Re-assert ownership and mode on **every**
   boot, because a restore drifts them.
4. **Fail loud.** Never silently regenerate the master key: every key Meilisearch issues is derived
   from it, so a silent regeneration invalidates every consumer's key without warning. If
   `data.ms` exists but the master key file does not, stop with a loud error rather than generate a
   new key.
5. **Code and docs ship together.** ADRs in `docs/decisions/`. The verified-versus-assumed log in
   `docs/PACKAGING-NOTES.md`, newest first. Box-specific working notes stay in gitignored
   `phase-notes/`.
6. **`CMD`, never `ENTRYPOINT`**, because `ENTRYPOINT` breaks Cloudron debug mode. Maintain
   `.dockerignore` as carefully as `.gitignore`.
7. **Open source only.** The package enables no Business Source License 1.1 enterprise edition
   feature (sharding, remote snapshot storage, and similar). If a future upstream release moves a
   feature this package relies on into that edition, record it in `docs/PACKAGING-NOTES.md` and
   `README.md` rather than enabling it silently.
8. **Anonymise before every push.** No box or mirror hostnames, no real emails beyond the declared
   `contactEmail`, no tokens, no internal URLs in any tracked file. `example.com` is the
   placeholder in public docs. `test/secret-scan.sh` is the release gate.
9. **Git hygiene.** No AI co-authorship and no tool-attribution trailers. Commit as the maintainer
   identity, set **repo-local**, because the machine global is a placeholder.

## Locked decisions (Phase 1, operator-confirmed 2026-07-30)

- **Manifest id:** `io.github.orcvole.meilisearch`. The repository's `-cloudron` suffix does not
  enter the id. `author` and `packagerName` are `OrcVole`.
- **Registry:** `ghcr.io/orcvole/meilisearch-cloudron`, pushed public so the box pulls without
  credentials. Tag scheme `<upstream-version>-<pkg-rev>`. Not yet built at this phase.
- **Repos:** GitHub `OrcVole/meilisearch-cloudron` is canonical. A private mirror also exists; its
  URL is maintainer-local and deliberately not recorded in tracked files.
- **memoryLimit:** 2147483648 (2 GB) to start, per the foundation brief. LMDB mmap makes VSZ
  meaningless; the shipped floor is to be confirmed by a cgroup RSS measurement under an indexing
  load once the image exists, not assumed from this starting value.
- **Health:** `healthCheckPath = /health`, the one route that stays open once a master key is set.
  Verify empirically, with and without a key, at the first gate ladder run.
- **Auth topology:** no addon-based authentication and no `proxyAuth`. `MEILI_ENV=production`
  enforces the master key; every route except `GET /health` requires it or a key derived from it.

## Pinned upstream

- `cloudron/base:5.0.0` (Ubuntu 24.04, glibc 2.39), digest to be pinned in the Dockerfile at the
  build phase from the current packaging skill reference.
- Meilisearch `1.51.0`, official GitHub release glibc binary for x86_64, pinned by sha256 once the
  Dockerfile exists. Licence: MIT AND BUSL-1.1, community features only.
- `meilitool`, from the same release if published as an asset, else extracted from the official
  `getmeili/meilisearch:v1.51.0` Docker image in a build stage (musl static; verify with `file`).

## Build shape

Not yet built; this is the scaffold phase. Per the foundation brief (ADR 0001): a builder stage
fetches and sha256-verifies the official release binary (and `meilitool`), and the final stage
copies it onto pinned `cloudron/base`. An `ldd` check at build time fails the build on any
unresolved symbol against the base image's glibc, rather than failing at runtime. If the glibc
binary does not resolve cleanly, the fallback is the musl-linked binary from the official Docker
image.

## Secrets

First-run only, idempotent, under `/app/data`, mode 0600, re-asserted on every boot.

| Secret | Shape | Criticality | Notes |
|---|---|---|---|
| `/app/data/master-key` | `openssl rand -hex 32` | data-loss-critical | Every issued API key is derived from it. Never regenerated once present; a missing key file next to an existing `data.ms` is a stop condition, not a reason to generate. |

Data-loss-critical secrets must be proven byte-identical, by sha256, across both an update and a
restore, once the entrypoint exists. Never record the value itself, in any file, ever. The digest
is the invariant.

## Environment mapping

Translate on every boot, once `start.sh` exists. Verified against the upstream documentation at
the Dockerfile phase, not from memory.

| Application variable | Source or value | Notes |
|---|---|---|
| `MEILI_ENV` | `production` | Forced, always. Enforces the master key and disables the built-in search preview UI. |
| `MEILI_HTTP_ADDR` | `0.0.0.0:7700` | Matches the manifest `httpPort`. |
| `MEILI_MASTER_KEY` | contents of `/app/data/master-key` | Generated once on first boot; never regenerated. |
| `MEILI_DB_PATH` | `/app/db/data.ms` | On the `persistentDirs` path. |
| `MEILI_SNAPSHOT_DIR` | `/app/data/snapshots` | Backed up by the ordinary file walk. |
| `MEILI_DUMP_DIR` | `/app/data/dumps` | Backed up by the ordinary file walk. |
| `MEILI_MAX_INDEXING_MEMORY` | computed from the cgroup memory limit at boot | Upstream sizes indexing buffers from host-visible RAM, not the cgroup, so this must be set explicitly (upstream issue 4686). |
| `MEILI_NO_ANALYTICS` | `true` | Forced, always. |

## Backup and restore

`/app/db` (the Meilisearch data store) is a Cloudron `persistentDirs` path, carried through every
backup, clone, and restore, and deliberately excluded from the ordinary `/app/data` file walk
because it churns under indexing. A `backupCommand` script (`/app/code/backup-snapshot.sh`, not yet
written) runs in a short-lived, unrelated container at backup time, asks the live instance over its
own API to take a snapshot, and writes it into `/app/data/snapshots`, which the ordinary file walk
does capture. There is no `restoreCommand`: the boot-time entrypoint (not yet written) detects an
empty `/app/db` (clone, or fresh install), a version-mismatched data store (package update or
rollback), or a normal restart, and imports the newest snapshot or dump accordingly. See
`docs/decisions/0004-data-layout-and-backup.md` and `docs/decisions/0005-boot-decision-tree.md`.

## Future compatibility

The single bump point for a version upgrade will be one build argument in the Dockerfile once it
exists, mirrored in the manifest `upstreamVersion`. A newer Meilisearch binary refuses to open an
older `data.ms` outright; the boot entrypoint runs `--upgrade-db` before the normal start when the
installed store is older than the binary, backstopped by Cloudron's automatic pre-update backup.
Sharding, remote (S3) snapshot storage, and other Business Source License 1.1 enterprise edition
features are deliberately out of scope; see `docs/decisions/0006-memory.md` for the memory posture
and `docs/FOR-UPSTREAM.md` for the cgroup memory detection note offered back to the Meilisearch
project.
