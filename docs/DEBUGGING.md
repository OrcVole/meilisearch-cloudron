# Debugging

A runbook for diagnosing this package on Cloudron. It is written so that an agent with only the
repository and the logs can find and fix a failure. When you fix a new failure, add it to "Known
failures" with the symptom, the cause, and the fix.

The image, entrypoint, and backup script now exist and have been exercised locally. The gate
tables below are still unrun, because a local container is not a Cloudron box. Do not fill a gate
row with anything that was not actually observed on a running box; local findings go in "Invariants
proven locally" instead.

## State on disk (where to look first)

- `/app/db/data.ms` is the Meilisearch data store, on the `persistentDirs` path. It never enters
  the ordinary `/app/data` backup file walk.
- `/app/db/.meili-version` is the boot-time version marker: a single line, the version of the
  binary that last reached a healthy start. It is written only after `/health` answers, so it never
  claims a version that failed to open the store.
- `/app/db/quarantine-<UTC timestamp>/data.ms` is a data store moved aside by leg 3 or leg 4. It is
  never deleted immediately; boot-time pruning removes it after 30 days.
- `/app/data/master-key` holds the generated master key, mode 0600, owner `cloudron`.
- `/app/data/snapshots/data.ms.snapshot` is the snapshot. Meilisearch always writes that one name
  and overwrites it in place, at mode 0444, so there is normally exactly one.
- `/app/data/dumps/*.dump` holds dumps, if any have been created. Nothing creates one
  automatically; the package only imports them.
- `/app/data/.endpoint` holds this container's own address as `http://<IPv4>:7700`, rewritten on
  every boot, because the backup container has no other way to find the application.
- `/app/data/.last-backup.log` holds one line per backup attempt, newest last, trimmed to 100
  lines. It is the only durable record of a backup run: the backup container's stdout is discarded
  by the platform.
- `/app/data/env`, if the operator created it, holds override settings. See the README.

## Boot sequence

Every package-emitted line is prefixed `==> [start]`, so `cloudron logs | grep '==>'` gives the
whole boot in order. The sequence is:

1. Create and take ownership of `/app/data` and `/app/db`; re-assert 0600 on the master key.
2. Write `/app/data/.endpoint` from the first IPv4 of `hostname -I`.
3. Source `/app/data/env` if it exists.
4. Compute `MEILI_MAX_INDEXING_MEMORY` from the cgroup limit, one third, floor 256 MiB. The log
   line names the limit, its source, and whether the value was computed or overridden.
5. Generate the master key if and only if this is a genuinely first run. A store present without a
   key file is a hard stop.
6. Apply the forced settings, which overwrite anything `/app/data/env` set for them.
7. Run exactly one leg of the decision tree, and say which one:
   - `leg: 1` no store. Import the newest snapshot, else the newest dump, else start empty.
   - `leg: 2` store present, marker matches the binary. Normal start.
   - `leg: 3` marker older than the binary, or missing. Run a supervised `--upgrade-db` process to
     completion, stop it cleanly, then start normally. On failure, quarantine and import a dump.
   - `leg: 4` marker newer than the binary, meaning a rollback restore. Quarantine the store and
     import the newest snapshot.
   Legs 3 and 4 only ever quarantine a store when there is an artefact to put in its place; with
   nothing to import they stop loudly and leave the store alone.
8. Prune to the newest two snapshots and dumps, and delete quarantined stores over 30 days old.
9. Start a background poller that writes the version marker once `/health` answers.
10. `exec /usr/bin/tini -- gosu cloudron:cloudron` into the server.

A normal boot is about one second to health. A boot through leg 3 takes about 50 seconds even when
there is nothing to migrate, because the script waits a grace period to be sure no upgrade task is
coming. If a boot seems to hang, check which leg the log named before assuming a fault.

## Invariants proven locally (not gate evidence)

Observed on a local container built from this repository on 2026-07-30. These are the things that
should stay true; if one of them stops being true, something has regressed.

| Invariant | How it was shown |
|---|---|
| The build fails on a wrong binary checksum | Deliberately wrong `sha256` build argument: `1 computed checksum did NOT match`, exit 1 |
| The build fails on an unresolvable binary | `ldd` gate greps for `not found` and runs `--version` on both binaries |
| `GET /health` needs no credential; everything else does | 200 unauthenticated; `GET /version` and search both 401 without the key, 200 with it |
| Production mode serves no search preview | `GET /` returns `{"status":"Meilisearch is running"}` as `application/json`, zero HTML |
| The master key is never regenerated | Second boot logs `existing key found`; a store without a key file exits 1 with a `FATAL` line |
| The store is never destroyed to make room for an import | Legs 3 and 4 check for an artefact before quarantining, and stop loudly if there is none |
| The version marker never claims an unhealthy start | Marker written only after `/health` answers; a stop mid-upgrade left it unchanged |
| A stop is honoured in every phase | 187ms normally, about 3s during a supervised upgrade, both exit 143 |
| The backup script never exits non-zero | Exit 0 with the app up, with the app stopped, and with an empty `/app/data` |
| The package's structural settings beat `/app/data/env` | Decoy file setting `MEILI_ENV=development` and `MEILI_DB_PATH=/tmp/hijacked` had no effect on either |
| Indexing memory follows the cgroup, not the host | 1 GiB limit produced `MEILI_MAX_INDEXING_MEMORY=357913941` |

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

Format: Symptom / Cause / Fix.

**Stopping, restarting, or updating the app takes the full grace period and ends in a kill.**
Cause: Meilisearch installs no `SIGTERM` handler, and a process running as PID 1 receives no
default signal dispositions from the kernel, so as PID 1 it ignores the signal outright. Measured
locally at a full 60 seconds of ignored `SIGTERM` followed by `SIGKILL` of a running database.
Fix: the entrypoint ends with `exec /usr/bin/tini -- gosu cloudron:cloudron ...` rather than
`exec gosu ...`. `tini` is already in `cloudron/base:5.0.0`, and upstream's own image uses it for
the same reason. If this symptom ever returns, check that line first. The same hazard applies
during the supervised upgrade phase, where `start.sh` itself is PID 1; that case is covered by a
`TERM`/`INT` trap in `start.sh` that forwards the signal, and losing that trap would reintroduce
the risk of a `SIGKILL` landing mid-migration.

**The app boots but every API key a consumer holds stops working.** Cause: the master key was
regenerated, which invalidates every key derived from it. The package is written so this cannot
happen by accident: a store present without a key file is a hard stop, not a regeneration. If it
happens anyway, the key file was replaced rather than restored. Fix: restore the original
`/app/data/master-key` from a backup; there is no way to re-derive the old keys from a new master
key.

**The boot appears to hang for about a minute after an update.** Usually not a fault. Check which
leg the log named. Leg 3 runs a supervised upgrade process and waits a grace period to be certain
no upgrade task is coming, which costs about 50 seconds even when there is nothing to migrate.

**Backups silently stop capturing a snapshot.** The backup command exits 0 by design in every
case, so a platform backup will look healthy regardless. Read `/app/data/.last-backup.log`: it
records `succeeded`, `skipped`, or `failed` with a reason and a timestamp for every attempt. A
run of `skipped` lines means the application was not reachable at backup time; a run of `failed`
lines with a missing endpoint file means it has not booted since install.

## When you are stuck

- Re-read `AGENTS.md`, especially the golden rules and the locked decisions.
- Re-read the relevant ADR in `docs/decisions/`; most failures are a conformance or topology
  mistake that was already reasoned about there.
- Reproduce locally with a local container run and a mounted data directory before blaming
  Cloudron.
- Record whatever you learn here so the next agent does not start from zero.
