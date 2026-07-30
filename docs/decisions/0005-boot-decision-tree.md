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
