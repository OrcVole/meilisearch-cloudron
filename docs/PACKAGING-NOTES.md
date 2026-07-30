# Packaging notes (verified-versus-assumed log, newest first)

Anonymised. Box-specific detail lives in the maintainer's local notes, not here.

---

## 2026-07-31: Phase 5, shipping image built, scanned, pushed and pinned; gate ladder blocked

The image that will ship now exists in the registry and its digest is pinned in the manifest. The
gate ladder did not start, because the platform cannot pull a private registry package.

**Verified:**

- The shipping image is built from the committed tree rather than the working copy. `git archive
  HEAD` was exported to a scratch directory and `podman build --no-cache` run there, so nothing
  uncommitted could enter the build context. The build reproduced the linkage gate exactly:
  `sha256sum -c` printing `/tmp/meilisearch: OK`, then `linkage gate passed for 1.51.0`.
- The secret and anonymity release gate passes over **both** surfaces for the first time. Until now
  only the repository file set had been scanned, because no image existed. The image scan greps
  `/app`, `/etc`, `/root`, `/home`, `/usr/local` and `/opt` inside the built image for box
  specifics, identities and credential shapes, and found none. The base image's three inert SSH
  host keys matched their pinned digests exactly: `3 found, 3 pinned-ok, 3 expected`. The
  pinned-digest allowlist written at the Dockerfile phase, which had never been exercised, works.
- **The digest to pin must come from the registry, not from the local image record.** Straight
  after a successful `podman push`, the local `RepoDigests` named a manifest the registry does not
  have: pulling it returns `manifest unknown`, while `skopeo inspect` against the tag returns a
  different digest. Pinning the local value would have produced a `dockerImage` no client could
  pull, and the failure would have surfaced only on a stranger's box. Resolve the digest with
  `skopeo inspect` against the registry every time.

**The blocker, stated plainly:** the platform pulls images with its own Docker daemon, and the
`cloudron` CLI has no option for registry credentials. A private registry package therefore cannot
be installed by digest at all; the install fails at the `Downloading image` step with
`statusCode: 401` and leaves the app in `error (pending_install)`. This is the ordering cost of
publishing the image before the ladder runs, and it is worth planning for: either the package is
made public before the ladder (which means publishing an unproven artefact, though only its
visibility, not any claim about it), or the host daemon is given credentials out of band. The
errored install was uninstalled so the location is free for the retry.

**Still assumed after this phase:** everything the gate ladder exists to prove. Nothing about
platform behaviour was learned, because nothing ran on the platform.

---

## 2026-07-30: Phases 2 to 4, Dockerfile, entrypoint, backup script, local smoke test

The image now exists and was exercised locally with rootless podman against throwaway data
directories. Everything in the "verified" list below was observed on a running container built
from this repository; everything in the "still assumed" list was not, and a local pass is not a
platform pass.

**Verified locally (one image, id `a9752b2e302f`, 2026-07-30):**

- The official 1.51.0 release binary for x86_64 resolves cleanly on `cloudron/base:5.0.0`. Its
  highest required symbol version is `GLIBC_2.35` against the base's 2.39. The build-time gate
  runs `file`, `ldd`, a grep for `not found`, and `--version` on both binaries, and passes. The
  musl fallback for the server binary was not needed.
- The build fails on a bad checksum. Building with a deliberately wrong `sha256` argument stops at
  `sha256sum -c` with `1 computed checksum did NOT match` and exit 1, rather than proceeding.
- Upstream publishes **no** checksum file with the release, and **no** `meilitool` release asset.
  The pinned hash comes from the `digest` field of the GitHub releases API asset object, confirmed
  against a locally computed `sha256sum`. `meilitool` comes from the official image, as ADR 0001's
  alternative path anticipated.
- `meilitool` is musl **dynamic**, not static. This corrects an assumption in ADR 0001; see that
  record's History section for how it is packaged.
- `GET /health` answers 200 with no credential while a master key is set. `GET /version` and
  `POST /indexes/*/search` answer 401 without the key, with the documented
  `missing_authorization_header` body, and 200 with it.
- Production mode really does remove the search preview interface. `GET /` returns
  `{"status":"Meilisearch is running"}` as `application/json`, with no HTML anywhere in the
  response.
- The master key is generated once at mode 0600 owned by `cloudron`, is not regenerated on a
  second boot, and a store present without a key file stops the boot with a labelled error rather
  than generating a replacement.
- The boot decision tree works for the clone leg (empty persistent directory plus a snapshot in
  `/app/data`) and the rollback leg (marker newer than the binary: store quarantined, snapshot
  imported, documents intact).
- `backupCommand` conditions were reproduced faithfully: a separate container, entrypoint
  overridden, read-only root filesystem, `/tmp` and `/run` as tmpfs, the same mounts, a shared
  network, and zero `CLOUDRON_*` variables (counted, not assumed). It exits 0 with the app up, with
  the app stopped, and with an entirely empty `/app/data`, recording the outcome each time.
- The cgroup memory computation is correct. Under a 1 GiB container limit the process received
  `MEILI_MAX_INDEXING_MEMORY=357913941`, exactly the limit divided by three, and the fallback to
  host `MemTotal` fires correctly when no limit is set.
- The `/app/data/env` override file works, and the package's structural variables win over it.
  Tested with a decoy file setting `MEILI_ENV=development` and `MEILI_DB_PATH=/tmp/hijacked`
  alongside legitimate settings: the legitimate settings took effect, both structural ones did not.
- `POST /snapshots` always writes the same file, `data.ms.snapshot`, overwriting it in place at
  mode 0444.

**Two defects the smoke test found, both now fixed, both worth remembering:**

- **Meilisearch ignores `SIGTERM` when it is PID 1.** It installs no handler, and the kernel gives
  PID 1 no default signal dispositions. Measured: a stop request was ignored for a full 60 second
  grace period and the container was then `SIGKILL`ed. The entrypoint now ends with
  `exec /usr/bin/tini -- gosu ...`, as upstream's own image does; the same stop then completed in
  187ms. This is a deviation from the literal last line in ADR 0002, recorded there. It very
  probably applies to other packages on this estate whose application does not install its own
  handlers, and the only symptom is slow stops.
- **The supervised upgrade phase reintroduced the same problem, worse.** During that phase
  `start.sh` is PID 1, so a stop arriving mid-migration was ignored until the platform `SIGKILL`ed
  a database in the middle of an upgrade. `start.sh` now traps `TERM` and `INT` and forwards them.
  Verified: the stop completes in about three seconds, the version marker is correctly left
  unchanged rather than claiming a version that never finished, and the next boot resumes the leg.

**Still assumed, not yet verified:**

- That the platform's health check tolerates the leg 3 boot window, which is about 51 seconds
  locally even with nothing to migrate, and includes a brief moment when the port is free between
  the supervised process stopping and the final start. Reasoned, not measured against Cloudron's
  checker.
- That a genuine format migration behaves as leg 3 assumes. Only one version was available
  locally, so the test was an artificially old marker against a current store. Observed honestly:
  when no upgrade is needed, Meilisearch enqueues **no** `upgradeDatabase` task at all, so the
  script waits a grace period and concludes the store was current. A real migration is the update
  drill's job.
- Every `--import-dump` branch. No dump was created in this round, so only the snapshot branches of
  legs 1, 3 and 4 ran.
- That a snapshot completes while a bulk index is churning, and within the ten minute poll timeout.
- That 2 GB and the divide-by-three fraction are right. Memory was verified as a computation, never
  under load.

---

## 2026-07-30: Phase 1, repository scaffold

The repository was created and populated with the manifest, licence, documentation, and the six
architecture decision records carried over from the architect's foundation brief. No Dockerfile,
entrypoint, or backup script exists yet; nothing in this round runs against a real box or a real
image, so nothing below is empirical. This entry exists to state plainly what is assumed at this
stage, so a later round does not mistake a design decision for a proven fact.

**Assumed, pending verification at later phases:**

- The official Meilisearch 1.51.0 release binary for x86_64 resolves cleanly with `ldd` against
  `cloudron/base:5.0.0`'s glibc 2.39 (assumed from the recon research agent's report that the
  release binary needs glibc >= 2.35; not yet run).
- `GET /health` stays open with no credential once a master key is set, and every other route,
  including `GET /version`, requires it (assumed from upstream documentation; not yet tested
  against a running instance with and without a key).
- `persistentDirs` semantics: empty on clone, preserved on in-place restore, possibly newer than
  the rest of a restored `/app/data` on a rollback restore (assumed from this estate's own prior
  verification of the mechanism on a different package; not yet re-verified for this one).
- The `--ignore-snapshot-if-db-exists` and equivalent dump flags exist and behave as documented,
  potentially simplifying the boot decision tree (assumed from the foundation brief; flag names
  and behaviour are to be confirmed against the actual binary's `--help` output and behaviour).
- `MEILI_MAX_INDEXING_MEMORY` divided from the cgroup limit by roughly three is a workable starting
  fraction (an estimate from the foundation brief, not derived from any measurement).

**Deviations from the foundation brief, recorded here as instructed by its own ground rules:**

- `CloudronManifest.json` omits a `dockerImage` field and an `iconUrl` field at this phase, because
  no image has been built and no `CloudronVersions.json` community channel exists yet; both are
  phase 2 and phase 9 concerns respectively, added once there is a real digest and a real published
  icon URL to reference. The manifest is otherwise complete against the foundation brief's field
  list.
- The logo is the official Meilisearch mark (the three-bar gradient icon at
  `assets/logo.svg` in the `meilisearch/meilisearch` repository), rendered to a 256x256 PNG on a
  white background with ImageMagick's built-in SVG renderer, matching this estate's own qdrant
  package's precedent for how an upstream vector mark becomes the packaged icon. Provenance is
  recorded in `phase-notes/phase-1-scaffold.md`.

**Still open:**

- Whether the release binary needs the musl fallback from the official Docker image, settled only
  once the Dockerfile's `ldd` gate actually runs.
- The exact wording Meilisearch returns for an unauthenticated request, and whether `GET /version`
  truly requires a key in the shipped version, settled only at Gate 1.
- The real cgroup RSS under an indexing load, and whether 2 GB is a workable shipped floor, settled
  only at Gate 4.

---

## Conventions for this file

- Newest first, so the top of the file is always the current state of knowledge.
- Every claim carries its evidence. "It works" is not an entry; "a 4 MiB upload returned 200 and the
  downloaded bytes were sha256-identical" is.
- Distinguish verified from assumed explicitly. An assumption written as a fact is the single most
  expensive thing this document can contain.
- Anything that generalises beyond this application gets harvested into the private field guide at
  the end of the round. This file is the application's record; the field guide is the doctrine.
- Gate ladder evidence tables live in `docs/DEBUGGING.md` or the relevant ADR. This file records what
  the gates taught, not the raw runs.
