# 0005: The boot-time decision tree covers every restore leg, so no restoreCommand exists

Status: accepted (every leg to be verified at Gate 3, against the shipping image digest)

## Context

`persistentDirs` semantics mean the `/app/db` path starts empty on a clone, is preserved by an
in-place restore, and is preserved (and can be newer than the rest of a restored `/app/data`) on a
rollback restore. A Meilisearch binary refuses outright to open a `data.ms` written by a newer
version, with an explicit version error rather than a silent, possibly corrupting migration
attempt, and an in-place `--upgrade-db` migration that is killed partway through can corrupt the
store (a known upstream risk). All of this has to be handled somewhere at boot regardless of
whether a separate `restoreCommand` also existed, because a clone and a plain first-time install
both present as "the persistent path is empty" to the entrypoint, and a `restoreCommand` cannot
distinguish an in-place restore from an ordinary restart either. Writing the logic once, at boot,
is simpler than splitting it across a boot script and a restore script that would both need most of
the same cases.

## Decision

`start.sh` (not yet written) maintains a version marker file, `/app/db/.meili-version`, recording
the binary version that last started cleanly, and works through these cases in order, after fixing
ownership and writing the endpoint file:

1. `data.ms` absent (a fresh install, or a clone, since `persistentDirs` starts empty on clone):
   launch with `--import-snapshot <newest> --ignore-missing-snapshot`. If no snapshot exists but a
   dump does (an older backup, or a cross-version clone), launch with
   `--import-dump <newest> --ignore-missing-dump` instead. A genuinely fresh install has neither,
   and starts clean.
2. `data.ms` present, marker equal to the running binary's version: a normal start.
3. Marker older than the binary (a package update): run the binary with `--upgrade-db` before the
   normal exec, so the migration runs to completion uninterrupted, backstopped by Cloudron's
   automatic pre-update backup. If the upgrade path itself fails, fall back to moving `data.ms`
   aside into a dated quarantine directory under `/app/db` and importing the newest dump.
4. Marker newer than the binary (a rollback restore, where the platform's preserved
   `persistentDirs` can be running a newer store than the rest of the restored `/app/data`): move
   `data.ms` aside the same way and import the newest snapshot, since it rode the same backup as
   the matching older binary version; the newest dump is the fallback if no snapshot exists.
5. On a healthy start, confirmed by the health endpoint answering, write the marker, and prune old
   snapshots, dumps, and quarantine directories older than two package updates.

No `restoreCommand` is declared. Import flags such as `--ignore-snapshot-if-db-exists` and the
equivalent dump flag may make some of these legs composable into fewer conditional branches; the
exact flag behaviour is to be verified empirically against the shipping binary rather than assumed
from documentation, before relying on it to simplify the script.

## Consequences

- One script, not two, owns every restore leg, which avoids duplicating the same case analysis
  across a boot script and a restore script that would otherwise both need to know about clones,
  rollbacks, and version mismatches.
- A killed-mid-upgrade corruption risk is mitigated by running `--upgrade-db` to completion before
  the health check window matters, and by Cloudron's own pre-update backup, rather than by trying
  to make the migration itself interruption-safe.
- This decision is entirely unexercised at the scaffold phase. Every numbered leg above, the exact
  version marker format, the composability of the `--ignore-*-if-db-exists` flags, and the pruning
  policy are to be written and proven against a real churning store at Gate 3, not assumed from
  this record.

## History

**2026-07-30, entrypoint phase.** Every leg is now implemented and four of the five are proven
locally. Three implementation decisions deserve recording, one of which departs from the literal
wording above.

- **Import flags confirmed against the binary, not the documentation.**
  `--import-snapshot`, `--ignore-missing-snapshot`, `--ignore-snapshot-if-db-exists`,
  `--import-dump`, `--ignore-missing-dump`, `--ignore-dump-if-db-exists` and `--upgrade-db` all
  exist in 1.51.0 with the behaviour assumed here. The script uses the explicit
  `--ignore-missing-*` pair rather than the `--ignore-*-if-db-exists` pair, because the tree
  already knows whether a store exists and an explicit branch reads more honestly than a flag
  that silently absorbs the difference.

- **A snapshot taken through the API is always the same file.** `POST /snapshots` writes
  `data.ms.snapshot` into the snapshot directory and overwrites it in place, at mode 0444.
  There is therefore normally exactly one snapshot file, and "the newest snapshot" is a
  degenerate choice. The retention logic is kept anyway, because it costs nothing and the
  built-in scheduled snapshots are the same shape.

- **Leg 3 binds the real port during the upgrade, which the wording above did not anticipate.**
  This record says the upgrade runs "before the normal exec", which is still true: a supervised
  process runs `--upgrade-db` to completion, is stopped cleanly, and only then does the final
  `exec` happen. What changed is that the supervised process binds `0.0.0.0:7700` like any other
  start, rather than staying off the network. Meilisearch enqueues the upgrade as an ordinary
  task and serves `/health` while that task runs, so binding normally keeps the platform health
  check satisfied for the entire migration. Keeping the port closed during a long migration would
  fail the health check and invite the platform to restart the container mid-migration, which is
  exactly the corruption this leg exists to prevent (upstream issue 5280).

  A second, sharper version of the same hazard was found and fixed while testing this leg. During
  the supervised phase, `start.sh` itself is PID 1, and PID 1 receives no default signal
  dispositions, so a stop request arriving mid-migration was ignored until the platform gave up
  and sent `SIGKILL` to a process in the middle of a database upgrade. `start.sh` now installs a
  `TERM`/`INT` trap that forwards the signal to the supervised process and waits for it. Measured
  locally: a stop request mid-upgrade now completes in about three seconds with exit code 143, the
  version marker is correctly left unchanged, and the next boot re-enters leg 3 and finishes the
  work.

- **A store with no marker at all is treated as leg 3, not leg 2.** A store that predates the
  marker, or one whose previous boot never reached health, is run through the supervised upgrade,
  which is a no-op against a store that is already current. Observed: when no upgrade is needed,
  Meilisearch enqueues no `upgradeDatabase` task at all, so the script waits a 20 second grace
  period before concluding the store was already current and moving on. That grace period is the
  price of the leg, and it is only paid when the marker is missing or old.

**Leg 3 against a genuinely older store remains unexercised.** With only one version available
locally, the test was a 1.50.0 marker against a store written by 1.51.0. That exercises the
branch, the supervised process, the no-task detection, the clean stop, and the marker advance,
but it does not exercise a real format migration. That is the X2 update drill's job.
