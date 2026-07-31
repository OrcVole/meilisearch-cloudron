# Meilisearch for Cloudron

This repository packages [Meilisearch](https://github.com/meilisearch/meilisearch), the open
source, typo-tolerant search engine written in Rust, as a Cloudron application. It keeps the
upstream binary unmodified and adds only a Cloudron-conformant runtime: a multi-stage Dockerfile,
an entrypoint that prepares and secures the runtime, a manifest, and the backup and restore
plumbing that a database-class application needs.

Meilisearch and the Meilisearch name and logo are trademarks of their respective owner. This
package is community-maintained and is not affiliated with or endorsed by the Meilisearch project.

## Architecture

Meilisearch runs as a single headless process in production mode, with no dashboard, no single
sign-on, and no LDAP or OIDC integration. The application exists to serve a search API to
programmatic clients, and placing Cloudron login in front of the whole domain would answer every
one of those clients with a login redirect instead of the search response they expect, which
defeats the point of the package. The one route Cloudron itself needs is `GET /health`, which
stays open even once a master key is set, so the platform health check needs no credential. Every
other route, including `GET /version`, requires the master key or a key derived from it. On first
launch the package generates the master key, stores it at `/app/data/master-key`, and never
regenerates it, because every key Meilisearch issues afterwards, including the default search and
admin keys and any scoped key an operator mints later through `POST /keys`, is derived from that
master key. Losing it, or letting it be regenerated, invalidates every key a consumer already
holds, so a missing key file next to an existing data store is treated as a stop condition rather
than a reason to generate a new one.

Persistent state is split across two locations with different treatment, because Meilisearch's
data store behaves like a database rather than a static file tree. The store itself (`data.ms`) is
an LMDB-backed structure that changes constantly under indexing, so it lives on a Cloudron
`persistentDirs` path (`/app/db`), a mechanism available from Cloudron 9.1 that keeps a hot,
churning store out of the ordinary backup file walk while still being carried through every
backup, clone, and restore. Everything else, including the master key, operator overrides, and the
retained snapshots and dumps, lives under the regular `/app/data` addon storage that Cloudron's
file walk backs up directly. A `backupCommand` script runs, at backup time, in a short-lived
container separate from the running application, and asks the live Meilisearch instance, over its
own API, to write a consistent snapshot into `/app/data`. On the next boot after a clone or an
in-place restore, when `/app/db` is found empty, the newest snapshot there, or the newest dump if
no snapshot exists, is imported back in. This two-tier design is what lets the package answer the
backup objection that Cloudron staff raised about Meilisearch in 2020, rather than working around
it.

## Install

Point the Cloudron CLI at a chosen domain and build on the server (no local Docker engine is
needed):

```
cloudron install --location search.example.com
```

The image is not yet published; this repository is at the scaffold stage. See
`docs/PACKAGING-NOTES.md` for the current state of the build.

## First steps

Meilisearch works immediately after install; there is no setup wizard.

**Read the master key.** Open this app's Terminal (the `>_` button) or run `cloudron exec`, then:

```
cat /app/data/master-key
```

**Use the key.** Send it as the `Authorization: Bearer <key>` header on every request except
`GET /health`, which stays open:

```
curl https://search.example.com/health
curl https://search.example.com/indexes -H "Authorization: Bearer <master-key>"
```

**Mint a scoped key for each consumer**, rather than handing out the master key itself, with
`POST /keys`:

```
curl -X POST https://search.example.com/keys \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  --data '{
    "description": "Example consumer, search only",
    "actions": ["search"],
    "indexes": ["*"],
    "expiresAt": null
  }'
```

Keep the master key itself out of application configuration wherever a scoped key will do; revoke
a scoped key at any time without disturbing any other consumer.

## Wiring to other applications

Each wiring change below is a stub for now, expanded as this package moves past the scaffold
stage. In every case, mint a scoped key for the consumer rather than sharing the master key, unless
the consumer's own documentation states that it requires full access.

**LibreChat.** LibreChat has native Meilisearch support for chat search, configured with
`SEARCH=true`, `MEILI_HOST`, and `MEILI_MASTER_KEY` (or a scoped key, if LibreChat's current
version supports one; verify against its own documentation before wiring). LibreChat rebuilds its
search index from its primary database, so pointing it at a fresh Meilisearch instance is low risk.

**Linkwarden.** Linkwarden has native Meilisearch support for full-text search over saved links,
configured through its own environment variables (name and shape to be confirmed against
Linkwarden's current documentation before wiring).

**Strapi.** The official `strapi-plugin-meilisearch` indexes Strapi content types into
Meilisearch. This is an optional plugin installed into the content management system itself, only
if the operator wants it; it is proposed here, not assumed.

**n8n.** No dedicated Cloudron wiring is needed. Use the community node `n8n-nodes-meilisearch`,
or a plain HTTP Request node against this application's REST API with a scoped key, from any n8n
workflow.

## Operator settings: /app/data/env

Create `/app/data/env` through the file manager or a terminal to override the defaults this
package computes. It is a plain shell fragment, one `KEY=value` per line, sourced by the
entrypoint before anything else is computed, and it takes effect on the next restart. It is read
with root's authority, so treat it as privileged.

| Variable | Default | Purpose |
|---|---|---|
| `MEILI_LOG_LEVEL` | `INFO` | `OFF`, `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE` |
| `MEILI_MAX_INDEXING_MEMORY` | cgroup limit divided by three | bytes of indexing buffer |
| `MEILI_MAX_INDEXING_THREADS` | half the available cores | indexing parallelism |
| `MEILI_SCHEDULE_SNAPSHOT` | `86400` | seconds between the built-in snapshots |
| `MEILI_HTTP_PAYLOAD_SIZE_LIMIT` | 100 MB | largest accepted request body |
| `MEILI_TASK_WEBHOOK_URL` | unset | a URL Meilisearch posts finished tasks to |
| `MEILI_EXPERIMENTAL_ENABLE_METRICS` | unset | `true` exposes the Prometheus route at `/metrics` |
| `MEILI_EXPERIMENTAL_CONTAINS_FILTER` | unset | `true` enables the `CONTAINS` filter operator |
| `MEILISEARCH_UPGRADE_TIMEOUT` | `3600` | seconds allowed for a data store upgrade at boot |
| `MEILISEARCH_HEALTH_TIMEOUT` | `300` | seconds to wait for health before giving up on the marker |
| `MEILISEARCH_RETAIN_SNAPSHOTS` | `2` | snapshot files kept in `/app/data/snapshots` |
| `MEILISEARCH_RETAIN_DUMPS` | `2` | dump files kept in `/app/data/dumps` |
| `MEILISEARCH_QUARANTINE_DAYS` | `30` | age at which a quarantined data store is deleted |

Any other `MEILI_EXPERIMENTAL_*` flag the pinned version accepts can be set the same way. Note
that the experimental features controlled through `PATCH /experimental-features` are runtime API
settings stored in the database, not environment variables, and are set with a request rather than
through this file.

The following are set by the package after this file is read, so setting them here has no effect:
`MEILI_ENV`, `MEILI_HTTP_ADDR`, `MEILI_DB_PATH`, `MEILI_SNAPSHOT_DIR`, `MEILI_DUMP_DIR`,
`MEILI_NO_ANALYTICS`, `MEILI_MASTER_KEY`, `MEILI_IMPORT_SNAPSHOT`, `MEILI_IMPORT_DUMP`, and
`MEILI_UPGRADE_DB`. The restore decision tree owns the import and upgrade variables, and the rest
are structural: changing them would move data out of the backed-up tree or turn off
authentication.

## Sizing: memory, disk, and how to bulk index without hurting

Measured on a real Cloudron, 2026-07-31, indexing one million small documents (about 400 bytes
each, over a deliberately large vocabulary) into a 2 GiB instance. The numbers are worth reading
before you plan a large import.

**Disk.** 401 MB of raw NDJSON became a **4.6 GB data store**, about **twelve times the input**.
Meilisearch trades disk for query speed, and the ratio surprises almost everyone. Plan disk at
roughly twelve times the size of the corpus you intend to index, not at its size.

**Memory, and which number to look at.** Three figures get quoted about a search engine and only
one of them means anything:

- **Virtual size is meaningless here.** Meilisearch memory-maps its store, so `ps` reports a
  virtual size of about **10 TB**. It is reserved address space, not memory. Ignore it completely.
- **Total memory usage sitting at 100 per cent of the limit is normal**, not a fault. Most of it is
  the operating system's page cache holding parts of the memory-mapped store, which the kernel
  drops the instant anything else needs the space. Any store larger than the memory limit will make
  the graph in Cloudron's dashboard sit near the top and stay there, with the application perfectly
  healthy.
- **Anonymous memory is the figure that decides whether the application survives.** In the test
  above it peaked at about **1.85 GB inside a 2 GB limit**, with another 660 MB pushed out to the
  host's swap. Total demand was around 2.5 GB.

**So: 2 GB is comfortable for tens of thousands of documents and ordinary query traffic, and it is
not enough to bulk-import a million documents in one go.** For a corpus of that size, give the
application **4 GB**. You can change the memory limit at any time from the application's Resources
page; nothing needs reinstalling.

**The single most useful thing you can do costs nothing.** Meilisearch merges every queued document
addition for the same index into one batch and processes it as a single unit of work. In the test
above, thirty-seven separate twenty-thousand-document requests were merged into one
**seven-hundred-and-forty-thousand-document** batch, and that batch is what set the memory peak.
So:

> When bulk importing, wait for each `documentAdditionOrUpdate` task to reach `succeeded` before
> sending the next batch. Poll `GET /tasks/<taskUid>`. Firing all your batches at once multiplies
> the peak memory by however many batches happen to be waiting.

Measured both ways on the same data: letting thirty-seven batches merge peaked at **1.85 GB** of
anonymous memory, while sending them one at a time peaked at **1.31 GB** and used a fifth as much
swap. Serialising is about three times slower per document, so it is a trade, not a free win — but
it is the difference between an import that fits and one that does not. Note also that a single
twenty-thousand-document batch still wants over 1.3 GB on its own, so client discipline alone does
not make a 2 GB instance comfortable for a corpus this size.

`MEILI_MAX_INDEXING_MEMORY` defaults to the memory limit divided by three. That is a sensible split
between the indexer and everything else, but it is **not** a ceiling on the process: the measured
peak was well above it. Lowering it in `/app/data/env` reduces pressure but does not bound total
usage.

## Backup, restore and update

Cloudron backs up `/app/data` as a live copy while the application keeps running, and separately
carries `/app/db`, the `persistentDirs` path, through every backup, clone, and restore. Because the
Meilisearch data store lives on that `persistentDirs` path, it does not enter the ordinary
`/app/data` file walk, so its constant background churn cannot abort or slow the backup of this
application or, in principle, of any other application sharing the same backup run.

The `backupCommand` script runs at backup time, asks the live server to take a snapshot over its
own API, and is best effort: it always exits cleanly, whatever it manages to capture, because a
backup step that could fail the whole platform backup for a transient condition is worse than one
that quietly falls short and leaves a record of doing so. A clone starts with an empty
`persistentDirs` path by Cloudron's own design, and an in-place restore preserves it; the
entrypoint distinguishes both cases from a normal restart and imports the newest snapshot, or the
newest dump if no snapshot exists, before Meilisearch opens for traffic. A rollback restore, where
an older `/app/data` (and therefore an older snapshot) is restored onto a rig that still has the
newer live data store from before the rollback, is handled the same way: the newer store is moved
aside and the older snapshot is imported, because a Meilisearch binary refuses to open a data store
newer than itself.

Updating rebuilds the image against a newer upstream release. Cloudron takes an automatic backup
before an `--image` update, which is the safety net for the in-place migration the entrypoint runs
(`--upgrade-db`) when the installed data store is older than the new binary. This project has not
yet exercised the ladder that proves this end to end; see `docs/PACKAGING-NOTES.md` for what is
verified versus assumed at the current stage, and `docs/decisions/` for the full reasoning behind
each of these choices.

## Documentation

- `docs/decisions/` carries the numbered architecture decision records behind this package.
- `docs/PACKAGING-NOTES.md` is the anonymised, verified-versus-assumed log for this package.
- `docs/FOR-CLOUDRON.md` carries platform observations offered back to the Cloudron team.
- `docs/FOR-UPSTREAM.md` carries packaging observations offered back to the Meilisearch team.
- `docs/DEBUGGING.md` is the runbook, including the gate evidence tables once they exist.
- `AGENTS.md` is the working contract for anyone, human or AI agent, who edits this repository.

## Licence

Meilisearch is dual licensed, `SPDX-License-Identifier: MIT AND BUSL-1.1`. The core engine,
including single-node self-hosting with local snapshots and dumps, is MIT licensed. A smaller
enterprise edition subset, covering features such as sharding and remote snapshot storage, is
licensed under the Business Source License 1.1 and requires a commercial agreement with Meilisearch
for production use. This package configures and runs only the MIT-licensed community engine; it
enables no enterprise edition feature. The package `LICENSE` file mirrors the exact upstream dual
licence, alongside the upstream `LICENSE-MIT` and `LICENSE-EE` texts it points to, unmodified. The
packaging work in this repository (the Dockerfile, the entrypoint, the manifest, and the
documentation) is the copyright of its author.
