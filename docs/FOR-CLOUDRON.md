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
