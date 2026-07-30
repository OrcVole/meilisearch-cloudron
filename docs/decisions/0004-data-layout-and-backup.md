# 0004: persistentDirs for the churning store, backupCommand for a consistent snapshot

Status: accepted (the full backup and restore cycle to be verified at Gate 3)

## Context

Cloudron's ordinary backup mechanism copies `/app/data` as a live file walk while the application
keeps running. Meilisearch's data store (`data.ms`) is LMDB-backed and changes constantly under
indexing; Cloudron staff raised exactly this objection to a Meilisearch package proposal in 2020
("it behaves like a database"), and the bounty offered for one at the time was never claimed.
Cloudron 9.1 introduced `persistentDirs` and `backupCommand`, which together let a package keep a
churning store out of the ordinary file walk while still carrying it through every backup, clone,
and restore, and let the package ask the running application itself for a consistent point-in-time
artefact rather than relying on a raw copy of a live store, which is not an officially sanctioned
recovery path for Meilisearch in any case.

## Decision

Declare `persistentDirs: ["/app/db"]` and set `MEILI_DB_PATH=/app/db/data.ms`, so the live,
churning store never enters the ordinary `/app/data` backup file walk. Set
`MEILI_SNAPSHOT_DIR=/app/data/snapshots` and `MEILI_DUMP_DIR=/app/data/dumps`, so that artefacts
Meilisearch itself writes do land in the backed-up tree; retain only the newest snapshot and the
newest dump, pruned at both boot time and backup time, so the backed-up tree does not grow without
bound. On every boot, write the container's first IPv4 address to `/app/data/.endpoint` as
`http://<ip>:7700`, following the same pattern already proven on this estate for another package
that needed a temporary container to reach a running sibling. Declare
`backupCommand: "/app/code/backup-snapshot.sh"` (not yet written), a script that runs in a
temporary, unrelated container at backup time with no `CLOUDRON_*` environment, a read-only root
filesystem, and only `/app/data` and `/app/db` mounted. It reads `.endpoint` and the master key,
calls `POST /snapshots` on the live instance, polls `GET /tasks/:uid` until the task succeeds or a
roughly ten-minute timeout is reached, writes a status line with a timestamp to
`/app/data/.last-backup.log` because its own stdout is not recoverable afterwards, and exits `0` in
every case, because a `backupCommand` that could fail the platform's entire backup run over a
transient condition is a worse failure mode than one that falls short quietly and leaves a written
record of doing so. There is no `restoreCommand`: restore logic lives entirely in the boot-time
decision tree (ADR 0005), which has to handle every one of these legs regardless of whether a
dedicated restore script also existed.

## Consequences

- The live, changing store never enters the ordinary backup file walk, which is the specific
  objection Cloudron staff raised in 2020, closed by a platform mechanism that did not exist at
  the time.
- A snapshot taken through the application's own API, while it is running, is what the application
  itself calls a consistent, restorable artefact, unlike a raw filesystem copy of a live LMDB
  store, which is not an officially sanctioned way to move Meilisearch data.
- The `backupCommand` script cannot learn the running application's own network address from its
  environment, because it runs in an unrelated temporary container with no `CLOUDRON_*` variables;
  the boot-written endpoint file is the workaround, and it is recorded as a platform observation in
  `docs/FOR-CLOUDRON.md`.
- This decision is unexercised at the scaffold phase: the endpoint file, the snapshot request and
  poll loop, the retention pruning, and the best-effort exit behaviour are all to be written and
  proven, not assumed, once `backup-snapshot.sh` exists and Gate 3 runs against a real churning
  store.

## History

**2026-07-30, backup script phase.** Written and proven locally, short of a real box.

`backup-snapshot.sh` was exercised the way the platform runs it: a second container from the same
image, entrypoint overridden to the script, read-only root filesystem, `/tmp` and `/run` as
tmpfs, the same `/app/data` and `/app/db` mounts, on a shared container network, and with zero
`CLOUDRON_*` variables in its environment (counted, not assumed). Results:

- With the application up: exit 0, snapshot task succeeded, `data.ms.snapshot` rewritten in the
  mounted snapshot directory, and one line appended to `/app/data/.last-backup.log`.
- With the application stopped: exit 0 in four seconds, recorded as `skipped` with the reason. The
  ten minute poll timeout is never reached, because an unreachable instance is detected by a short
  health probe before any snapshot is requested.
- With an empty `/app/data` and no endpoint file at all: exit 0, recorded as `failed` with the
  reason. This is the state a backup would find if it ran before the application had ever booted.

The status log rotates at 100 lines. Retention pruning runs in the backup script as well as at
boot, so the tree the platform is about to walk carries the newest artefacts only.

One correction to the expectation recorded above: `POST /snapshots` always writes the same file
name, `data.ms.snapshot`, overwriting it in place at mode 0444. "Retain only the newest snapshot"
is therefore what Meilisearch does by itself; the retention code is kept for the dump directory
and for defence against a future naming change.

The endpoint file works as designed and is the only reason the temporary container can find the
application. `hostname -I` was filtered for the first IPv4 rather than the first field, because it
can lead with an IPv6 address.
