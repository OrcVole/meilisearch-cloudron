# 0006: A 2 GB starting memoryLimit, measured rather than assumed, RSS rather than VSZ

Status: accepted (Gate 4 measurement not yet performed)

## Context

Meilisearch's storage engine is memory-mapped LMDB, so its virtual memory size grows to reflect the
size of the store on disk regardless of how much of it is actually resident, which makes VSZ
meaningless as a sizing signal for a container memory limit. Separately, an upstream issue (4686)
documents that Meilisearch sizes its indexing buffers from host-visible RAM rather than the
container's cgroup limit, which on a memory-constrained container risks an indexing operation
requesting more than the container is actually allowed, ending in an out-of-memory kill rather than
a controlled failure.

## Decision

Start with `memoryLimit: 2147483648` (2 GB), the operator-confirmed starting point from the
foundation brief, understood explicitly as a starting point rather than a measured floor: Gate 4
will measure cgroup RSS plus swap under a realistic indexing load once the image exists, and the
shipped default is to be revisited from that evidence, not left at this value by default. The
entrypoint, once written, computes `MEILI_MAX_INDEXING_MEMORY` explicitly from the cgroup memory
limit at every boot, roughly limit divided by three, so that Meilisearch's own buffer sizing never
exceeds what the container is actually permitted, regardless of how much RAM the underlying host
happens to have. This computation, and the divisor, are to be verified empirically rather than
trusted as a fixed constant, because the right fraction depends on how upstream's buffer sizing
behaves in practice under indexing.

## Consequences

- Gate 4 must read cgroup accounting (resident set size and swap), not virtual memory size, or the
  measurement will overstate memory pressure that does not actually exist.
- Documenting for operators, once the entrypoint exists, that indexing is the memory-hungry phase
  of running Meilisearch, and that raising the memory limit is the direct lever if indexing a large
  corpus is killed.
- The upstream host-RAM sizing behaviour (issue 4686) is offered back to the Meilisearch project in
  `docs/FOR-UPSTREAM.md`, because cgroup-aware sizing would remove the need for this package (and
  every other container packaging of Meilisearch) to compute the value itself.
- This decision is unexercised at the scaffold phase: no image exists yet, so the 2 GB starting
  point, the divide-by-three computation, and the actual cgroup RSS under load are all to be
  measured, not assumed, at Gate 4.

## History

**2026-07-30, entrypoint phase.** The computation is implemented and proven; the limit itself is
still unmeasured.

`start.sh` reads `/sys/fs/cgroup/memory.max` (cgroup v2), falls back to
`/sys/fs/cgroup/memory/memory.limit_in_bytes` (cgroup v1), and falls back again to `MemTotal` from
`/proc/meminfo` when neither carries a real limit, which covers both the cgroup v2 `max` sentinel
and the enormous sentinel cgroup v1 uses. The result is divided by three with a 256 MiB floor and
exported as `MEILI_MAX_INDEXING_MEMORY`, and the resolved value and its source are logged on every
boot.

Verified locally with a 1 GiB container limit: the container read `1073741824` from
`memory.max`, the entrypoint logged `limit 1024 MiB from cgroup v2 memory.max; indexing memory
341 MiB (limit / 3, floor 256 MiB)`, and the running process's environment carried
`MEILI_MAX_INDEXING_MEMORY=357913941`, which is exactly the limit divided by three. With no
container limit set, the same code correctly reported that it had fallen back to host `MemTotal`.
An operator value in `/app/data/env` is honoured instead of the computed one, and the log says so.

The divisor and the 2 GB `memoryLimit` remain unmeasured against a real indexing load. That is
Gate 4's job.
