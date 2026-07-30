# Debugging

A runbook for diagnosing this package on Cloudron. It is written so that an agent with only the
repository and the logs can find and fix a failure. When you fix a new failure, add it to "Known
failures" with the symptom, the cause, and the fix.

This file is a gate-evidence skeleton. No Dockerfile, entrypoint, or backup script exists yet, so
none of the sections below carry evidence; they are the shape the evidence will take once the gate
ladder runs against a real image. Do not fill a row with anything that was not actually observed on
a running box.

## State on disk (where to look first)

To be filled in once `start.sh` exists. Expected, per the architecture decision records:

- `/app/db/data.ms` is the Meilisearch data store, on the `persistentDirs` path.
- `/app/db/.meili-version` is the boot-time version marker.
- `/app/data/master-key` holds the generated master key (mode 0600).
- `/app/data/snapshots/` and `/app/data/dumps/` hold the retained backup artefacts.
- `/app/data/.endpoint` holds the container's own address, written on every boot, for the
  `backupCommand` script to read.
- `/app/data/.last-backup.log` holds the most recent `backupCommand` outcome.

## Boot sequence

To be filled in once `start.sh` exists, following the same shape as the decision tree in
`docs/decisions/0005-boot-decision-tree.md`.

## Gate evidence tables

Each gate below is unrun. When a gate runs for real, replace its row with the actual evidence: a
status code, a hash, a count, a log line, and the date. An inference is not evidence.

### Gate 0: install and first boot

| Check | Expected | Evidence |
|---|---|---|
| Image builds | Build completes, `ldd` gate passes | not yet run |
| Container starts | Health check passes within the boot timeout | not yet run |
| Master key generated | `/app/data/master-key` present, mode 0600 | not yet run |

### Gate 1: auth

| Check | Expected | Evidence |
|---|---|---|
| `GET /health` with no key | 200 | not yet run |
| `GET /version` with no key | 401 (or documented equivalent) | not yet run |
| Any data route with the master key | 200 | not yet run |
| `POST /keys` mints a working scoped key | New key authenticates; original master key unaffected | not yet run |

### Gate 2: functional flows

| Check | Expected | Evidence |
|---|---|---|
| Index one document | Task succeeds | not yet run |
| Search returns it | Document present in results | not yet run |
| Filter narrows results | Correct subset returned | not yet run |
| Delete removes it | Subsequent search excludes it | not yet run |
| Integration gate (a throwaway consumer, for example LibreChat, against the test install) | End-to-end search succeeds | not yet run |

### Gate 3: update and restore

| Check | Expected | Evidence |
|---|---|---|
| In-place restore | Data and master key survive | not yet run |
| Clone restore (empty `persistentDirs`) | Snapshot or dump imports; data present | not yet run |
| Rollback restore | Newer store moved aside; matching snapshot imported | not yet run |
| Backup while indexing | Backup completes without corrupting the live index | not yet run |

### Gate 4: memory

| Check | Expected | Evidence |
|---|---|---|
| cgroup RSS at idle | Recorded | not yet run |
| cgroup RSS during bulk indexing of a realistic corpus | Recorded, with the corpus described | not yet run |
| Swap usage during indexing | Recorded | not yet run |

## Known failures

Format: Symptom / Cause / Fix. Empty until a real failure is observed and fixed.

## When you are stuck

- Re-read `AGENTS.md`, especially the golden rules and the locked decisions.
- Re-read the relevant ADR in `docs/decisions/`; most failures are a conformance or topology
  mistake that was already reasoned about there.
- Reproduce locally with a local container run and a mounted data directory before blaming
  Cloudron.
- Record whatever you learn here so the next agent does not start from zero.
