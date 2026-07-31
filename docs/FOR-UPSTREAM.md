# Notes for the Meilisearch team

Packaging observations from running Meilisearch as a Cloudron application, offered gratefully and
with evidence. Anonymised: no box or maintainer specifics. None of this is a contribution to the
Meilisearch project itself, only a note about packaging experience; any actual upstream
contribution would go through Meilisearch's own contribution process, not this repository.

Measurements below were taken at package version 1.0.0 against Meilisearch 1.51.0, on an
Intel Xeon E5-2650 v4 host, in a container with cgroup v2 memory limits and uncapped swap. The
corpus was deliberately pessimistic: one million small documents generated deterministically from a
200,000 token Zipf vocabulary, 401 705 492 bytes of NDJSON, sent as fifty batches by a
fire-and-forget client. It is a worst case, not a typical workload.

## Indexing memory is not bounded by `MEILI_MAX_INDEXING_MEMORY`

The observation that surprised us most. With `MEILI_MAX_INDEXING_MEMORY` set to 682 MiB for the
whole run, peak anonymous memory reached **1 981 636 608 bytes, about 1.85 GiB**, roughly 2.8 times
the configured value. Against a 2 GiB container limit that is 92 per cent of the cap, and the
process survived only because the platform grants containers uncapped swap: 661 164 032 bytes of
swap were in use simultaneously with the anonymous peak. On a swapless host the same run would very
likely have been killed. Raising the limit to 4 GiB and repeating the identical run gave a peak of
1 954 820 096 bytes, essentially the same working set, at 46 per cent of the cap and with **zero**
swap in use at the peak, which suggests the earlier swap was pressure rather than demand.

The proximate cause appears to be automatic batching rather than corpus size. At the 2 GiB limit one
batch reported `totalNbTasks: 37` with `receivedDocuments: 740000`. A control run sending the same
fifty batches strictly serially, waiting for each task to succeed, peaked at 1.31 GiB anonymous with
135 MB of swap, at roughly three times the wall clock per document. A single 20 000 document batch
still wanted more than 1.3 GiB.

We are not claiming `MEILI_MAX_INDEXING_MEMORY` is broken: it may well bound one specific structure
faithfully while other allocations dominate. The packaging-relevant point is narrower, and it is
that **the setting cannot currently be used to size a container**, because the process can exceed it
severalfold under ordinary bulk indexing. A packager who sizes a memory limit from that setting will
ship an application that is killed under load.

**Suggestion:** documenting what the setting does and does not bound would help packagers
considerably, even if the behaviour itself does not change. If a genuine ceiling on indexing memory
is feasible, it would let container packagers size limits with confidence instead of by measurement.

## Indexing memory sizing does not appear to be cgroup-aware

Publicly tracked as upstream issue 4686: Meilisearch appears to size its indexing buffers from
host-visible memory rather than from the cgroup limit enforced on the process. Inside a container
capped well below the host total, an indexing operation can therefore size buffers as though the
full host memory were available.

This package computes `MEILI_MAX_INDEXING_MEMORY` explicitly from the cgroup limit at every boot
(one third of the limit, an estimate rather than a measured constant) and sets it every time rather
than relying on any auto-detected default. Every container packager of Meilisearch has to reinvent
the same computation and guess at the same fraction, which a cgroup-aware default would remove.
Note that this mitigation is partial, for the reason in the section above.

**Suggestion:** reading `/sys/fs/cgroup/memory.max` (cgroup v2), or the cgroup v1 equivalent, when
sizing indexing buffers would remove the workaround for every container packaging of Meilisearch.

## Snapshots carry the task queue, which is useful and undocumented

Verified while proving backup and restore. A snapshot taken through `POST /snapshots` while
indexing was in flight, then restored into an empty store on a different installation, converged to
**680 000** documents: 260 000 committed at the snapshot's consistency point plus 420 000 that were
still queued as undrained task payloads and were replayed on start. Nothing was lost.

This is genuinely good behaviour and it made a live backup safe to design around, but we could not
find it stated in the documentation, and the consistency point being the task's start rather than
the moment the snapshot is requested is the sort of detail a packager has to discover empirically.

**Suggestion:** a sentence in the snapshots documentation confirming that queued tasks travel with a
snapshot, and defining the consistency point, would save that discovery.

## A dump import is a full re-index, which interacts badly with platform health checks

Restoring by `--import-dump` re-indexes rather than restoring an index, which is documented and
understood. The packaging consequence is worth naming: for 680 000 documents the import took about
seven minutes before the HTTP listener answered, which exceeds the readiness windows some platforms
allow before they restart a container. A restart mid-import risks leaving the store in the state the
import was meant to repair.

**Suggestion:** nothing is required of Meilisearch here, but a note in the dumps documentation that
import time scales with corpus size and that the listener does not answer until it completes would
help packagers set health check timeouts deliberately rather than discovering the interaction.

## Small notes, offered as compliments with a caveat

The release process made digest pinning straightforward and the asset naming is predictable. The
one gap: releases carry **no checksum file**, so the GitHub API asset `digest` field was the only
upstream published hash available to verify a download against. A `SHASUMS` asset would let
packagers verify without depending on the API.

`--upgrade-db` being promoted out of experimental status in 1.51.0 is exactly what a packager wants
for unattended updates, and the package depends on it. One observation: when the store is already
current, no `upgradeDatabase` task is enqueued at all and `GET /tasks?types=upgradeDatabase` returns
an empty list, so a package cannot distinguish "migration completed" from "no migration was needed"
by polling. A no-op task, or any explicit signal, would make that distinguishable.

## Status of these notes

Every measurement above was taken during the package's acceptance gates and is recorded with its
evidence in `docs/DEBUGGING.md`. The one claim this package has **not** been able to test is a real
cross-version database migration, because no newer upstream release existed during packaging; the
`--upgrade-db` path has been exercised only against a store the same version wrote. That will be
retested at the first genuine version bump, and these notes updated.
