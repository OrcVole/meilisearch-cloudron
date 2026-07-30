# Packaging notes (verified-versus-assumed log, newest first)

Anonymised. Box-specific detail lives in the maintainer's local notes, not here.

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
