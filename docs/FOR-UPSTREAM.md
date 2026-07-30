# Notes for the Meilisearch team

Packaging observations from running Meilisearch as a Cloudron application, offered gratefully and
with evidence where evidence exists. Anonymised; no box or maintainer specifics. None of this is a
contribution to the Meilisearch project itself, only a note about packaging experience; any actual
upstream contribution would go through Meilisearch's own contribution process, not this repository.

## Indexing memory sizing does not appear to be cgroup-aware

Publicly tracked as upstream issue 4686: Meilisearch appears to size its indexing buffers from
host-visible memory rather than from the cgroup limit actually enforced on the process. Inside a
container whose memory is capped well below the host total, an indexing operation can therefore
size its working buffers as though the full host memory were available, risking an out-of-memory
kill rather than the graceful backpressure a cgroup-aware sizing calculation could offer instead.

This package works around the gap by computing `MEILI_MAX_INDEXING_MEMORY` explicitly from the
cgroup memory limit at every container boot (roughly one third of the limit, an estimate rather
than a measured constant; see `docs/decisions/0006-memory.md`), and setting it every time rather
than relying on any auto-detected default. This is a reasonable package-side mitigation, but every
container packager of Meilisearch has to reinvent the same computation and guess at the same
fraction, which a cgroup-aware default inside Meilisearch itself would remove entirely.

**Suggestion:** if Meilisearch does not already read `/sys/fs/cgroup/memory.max` (cgroup v2) or the
equivalent cgroup v1 path when sizing indexing buffers, doing so would remove the need for this
workaround, and for the equivalent workaround in any other container packaging of Meilisearch.

This note reflects packaging-side experience and the public issue number only; it is not itself a
measurement of Meilisearch's actual sizing algorithm, which is to be confirmed empirically (Gate 4)
before this note is refined further or actually raised with the Meilisearch project.
