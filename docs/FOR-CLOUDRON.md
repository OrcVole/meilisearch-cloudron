# Notes for the Cloudron team

Verified platform observations from packaging Meilisearch, offered back in the spirit of making
Cloudron better for this class of application: a single-binary, memory-mapped data engine with a
programmatic API and no dashboard of its own. Anonymised; no box or maintainer specifics.

## backupCommand runs in a container that cannot learn the running application's own address

A `backupCommand` script executes in a short-lived, unrelated container: the same image, but with
no `CLOUDRON_*` environment variables, a read-only root filesystem, and only the declared
persistent paths mounted. For an application like Meilisearch, where the only supported way to take
a consistent backup artefact is to ask the live, running instance over its own HTTP API (there is
no safe way to copy the on-disk store directly while it is open), the backup script needs to know
where that live instance actually is on the network. Nothing in the `backupCommand` container's
environment says so.

The workaround this package uses, seen before on this estate for a different application with the
same shape of problem: on every boot, the ordinary application container writes its own first IPv4
address to a file under the ordinary addon storage (for example `/app/data/.endpoint`), and the
`backupCommand` script reads that file at backup time to learn where to send its API calls. This
works, but it is indirect, and it depends on the address in that file still being live and correct
at the moment the backup runs, which is usually true but is not a Cloudron-provided guarantee.

**Suggestion:** consider exposing the application's own reachable address (or container hostname)
to the `backupCommand` environment directly, even though the rest of the `CLOUDRON_*` environment is
deliberately withheld from that container for good reason. This would remove an entire class of
workaround for every package whose backup story is "ask the live application for a consistent
snapshot", which is likely to be the correct backup story for any application built on a
memory-mapped or write-ahead-logged storage engine, not just this one.

This observation is unverified against Cloudron's own source or issue tracker at the time of
writing; it reflects packaging-side experience only. [verify against Cloudron's own documentation
and issue tracker before treating this as a confirmed platform gap.]

**Update after Gate 3, 2026-07-31: the workaround was exercised in production conditions and it
held.** The boot-written endpoint file was correct across an install, a restart, an in-place restore
and a clone, including a backup taken while the application was indexing a million documents. The
suggestion stands, but it is a convenience, not a blocker.

## A per-app memory graph pinned at 100 per cent is normal for a memory-mapped store, and looks alarming

Measured on a 2 GiB app: after indexing a corpus larger than the memory limit, the container's
`memory.current` sits at 94 to 100 per cent of `memory.max` indefinitely, with the application idle
and perfectly healthy. Almost all of it is `memory.stat file` — clean, reclaimable page cache
backing the memory-mapped data store, which the kernel drops the instant anything else needs it.
The figure that actually predicts an OOM is `memory.stat anon`, which in the same steady state was
under a third of the limit.

Any application built on a memory-mapped engine (LMDB, RocksDB with mmap, SQLite in some
configurations, most embedded search engines) will look like this. An operator reading Cloudron's
memory graph will reasonably conclude the app is about to die, and raise a support question, or
raise the limit and see the graph pin at the new limit too.

**Suggestion:** consider distinguishing reclaimable page cache from anonymous memory in the per-app
memory display, or at least documenting the distinction where the graph is explained. A second
line, or a note that "cache" is not "used", would resolve a recurring class of false alarm.

## `oom_kill` is a weak health signal on a host with swap

Related, and worth stating because it affects how a packager should size an app. During a load that
pushed anonymous memory to 1.85 GiB inside a 2 GiB limit, the container was never OOM-killed: the
kernel wrote roughly 660 MB out to the host's swap and faulted it back 165 068 times, with 30 867
reclaim-at-limit events and sustained memory pressure. The application stayed healthy and answered
every health check. On a host without swap, the same workload would have had nowhere to put those
pages.

This means a package can pass an "it was never OOM-killed" test on one host and fail on another
with the same memory limit, purely on swap configuration. **Suggestion:** where Cloudron documents
`memoryLimit`, it may be worth noting that host swap silently absorbs overshoot, and that
`memory.stat anon` rather than the kill counter is the figure a packager should size against.
