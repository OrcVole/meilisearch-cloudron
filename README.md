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

Requires Cloudron 9.1.0 or newer, because the package uses `persistentDirs`, `backupCommand`, and
`iconUrl`, all of which arrived in 9.1.

**From the Cloudron dashboard (recommended).** In the App Store, open the **Add custom app**
dropdown at the top right, choose **Community app**, and paste this URL:

```
https://raw.githubusercontent.com/OrcVole/meilisearch-cloudron/main/CloudronVersions.json
```

Applications installed this way receive updates automatically as new versions are published.

**From the CLI**, which does the same thing:

```
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/meilisearch-cloudron/main/CloudronVersions.json \
  --location search.example.com
```

**Building on the server instead**, for a box below 9.1.0 or for local modifications, from a clone
of this repository:

```
cloudron install --location search.example.com
```

The published image is `ghcr.io/orcvole/meilisearch-cloudron`, pinned by digest in both
`CloudronManifest.json` and `CloudronVersions.json`. It is public and pulls without credentials.

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

Both worked examples below were carried out against a real Cloudron and are written from what the
applications actually did, not from their documentation. Hostnames are `example.com` placeholders.
Note that where these instructions say `/app/data/env`, they mean the **consumer's** file, inside
the consumer's own container — not this package's operator settings file of the same name.

### The method, whatever the consumer is

1. **Find the consumer's real configuration mechanism before changing anything.** Read its
   `/app/pkg/start.sh` and its supervisor configuration inside the container
   (`cloudron exec --app <location>`). A Cloudron package usually assembles a runtime environment
   file from several sources in a fixed order, and only one of those sources is yours to edit.
   `cloudron env list --app <location>` tells you whether the dashboard environment mechanism is in
   play as well. Do not assume the answer; two of the two applications wired this way turned out to
   differ from what their upstream documentation implies.
2. **Confirm the consumer has a recent backup** with `cloudron backup list --app <location>`. If it
   does not, stop and fix that first.
3. **Mint a dedicated scoped key** with `POST /keys`, restricted to the indexes that consumer owns
   and to the actions it actually calls. Derive the action list from the consumer's source at its
   installed version, not from its README. Then **prove the key before you touch the consumer**, by
   driving the same call sequence against this application with `curl`, and by checking that a few
   calls outside the scope really are refused with `403`.
4. **Deliver the key without letting it reach a command line.** `cloudron push` a mode-0600
   fragment file into `/app/data`, append it inside the container, and delete the fragment.
   `cloudron exec` puts its command on the container's command line, where `ps` can read it.
5. **Keep a byte-exact pre-image.** Copy the configuration file to
   `<file>.pre-meili-wiring-<date>` inside the container before editing it, and record its sha256.
   That, plus the key `uid` to revoke, is the whole rollback.
6. **Expect a restart, and measure the outage yourself.** Poll the consumer's own URL once a second
   from outside, and quote that figure to the operator rather than "a restart". Both applications
   wired this way were unavailable for about two minutes, and both took a further minute after
   that to stop timing out occasionally while their first pages rendered.

**Mind the "already indexed" flag.** Every consumer of this kind keeps a per-row marker in its own
database saying "this row is in the search index". Point an established consumer at a *fresh*
Meilisearch and those markers are all still set, so the consumer concludes there is nothing to do
and the new instance stays permanently empty while search silently returns nothing. Before you
declare a wiring successful, check the document count in `GET /stats` against the row count in the
consumer's own database. If they disagree, find the consumer's documented resync mechanism and use
that — never delete data to force it.

### LibreChat

**Check first whether it needs this application at all.** The Cloudron LibreChat package ships and
supervises its *own* private Meilisearch on `localhost:7700`, with its store in
`/app/data/meili_data` and a generated master key in `/app/data/secrets.env`. Chat search there is
not broken for want of a search engine. Pointing it at this application is a deliberate
consolidation — one backed-up, separately sized, shared instance instead of a private one — and not
a repair.

Configuration goes in **`/app/data/env`**, which the package appends last to the runtime
environment file and then sources, so it overrides the package's own defaults:

```
MEILI_HOST="https://search.example.com"
MEILI_MASTER_KEY="<the scoped key for this consumer>"
```

`SEARCH=true` is already set by the package. Tighten the file to mode `0600` afterwards; it now
holds a credential, and the package re-owns `/app/data` on each boot but does not re-chmod it.

A key scoped to indexes `["convos","messages"]` with actions `search`, `documents.add`,
`documents.get`, `documents.delete`, `indexes.create`, `indexes.get`, `settings.get`,
`settings.update`, `tasks.get` is sufficient — verified against LibreChat v0.8.1 with zero `401` or
`403` in the engine's access log. `settings.get` is easy to miss and is required: LibreChat reads
the index settings on every boot. Do not grant `stats.get`; it is not called, and a globally scoped
`GET /stats` is refused for an index-scoped key in any case.

Two behaviours that look like faults and are not. LibreChat registers its models twice, so it
issues duplicate `POST /indexes` calls and leaves one **`failed` `indexCreation` task** per index
in `GET /tasks` with `Index ... already exists`; it catches this itself and carries on. And
LibreChat's resync marker is `_meiliIndex` on each conversation and message document — see the
warning above.

### Linkwarden

Linkwarden has no bundled search engine, so this wiring genuinely turns full text search on. Its
configuration also goes in **`/app/data/env`**, which the package appends to the runtime `.env`
file the application reads:

```
MEILI_HOST="https://search.example.com"
MEILI_MASTER_KEY="<the scoped key for this consumer>"
```

Linkwarden builds its client only when `MEILI_MASTER_KEY` is set, and otherwise falls back to
database search silently, which is why the feature can appear simply missing.

A key scoped to index `["links"]` with actions `search`, `documents.add`, `documents.delete`,
`indexes.create`, `indexes.get`, `settings.update`, `tasks.get` is sufficient. It needs neither
`documents.get` nor `settings.get`.

After the restart, the worker process creates the `links` index, writes its filterable and sortable
attributes, and then back-fills every existing link in batches of 50, marking each row's
`indexVersion` in its own database as it goes. Measured rate: **4 867 links in 49 minutes**, about
one and a half per second, so plan for roughly an hour per five thousand links; the application
stays responsive throughout and the engine barely notices. Note that the web process starts
accepting searches a few seconds before the worker has created the index, so the first half-minute
after the restart can log `MeiliSearchApiError: Index 'links' not found` against real searches.
That is a transient startup race and it clears itself; create the index ahead of the restart if the
window has to be invisible. Linkwarden's resync marker is that `indexVersion` column.

### Strapi

The official `strapi-plugin-meilisearch` indexes Strapi content types into Meilisearch. This is an
optional plugin installed into the content management system itself, only if the operator wants it;
it is proposed here, not assumed.

### n8n

No dedicated Cloudron wiring is needed. Use the community node `n8n-nodes-meilisearch`, or a plain
HTTP Request node against this application's REST API with a scoped key, from any n8n workflow.

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

Measured on a real Cloudron, 2026-07-31, indexing the same one million small documents (about 400
bytes each, over a deliberately large vocabulary) twice: once into a 2 GiB instance and once into
the 4 GiB instance this package now ships. The numbers are worth reading before you plan a large
import.

**Disk.** 401 MB of raw NDJSON became a **4.9 GB data store**, about **twelve times the input**.
Meilisearch trades disk for query speed, and the ratio surprises almost everyone. Plan disk at
roughly twelve times the size of the corpus you intend to index, not at its size.

**Memory, and which number to look at.** Three figures get quoted about a search engine and only
one of them means anything:

- **Virtual size is meaningless here.** Meilisearch memory-maps its store, so `ps` reports a virtual
  size measured in terabytes, anywhere from about 2 TB to about 22 TB depending on how much of the
  address space the store currently reserves. It is reserved address space, not memory. Ignore it
  completely.
- **Total memory usage sitting at 100 per cent of the limit is normal**, not a fault. Most of it is
  the operating system's page cache holding parts of the memory-mapped store, which the kernel
  drops the instant anything else needs the space. Any store larger than the memory limit will make
  the graph in Cloudron's dashboard sit near the top and stay there, with the application perfectly
  healthy. Raising the memory limit does not change this: the page cache simply expands to fill it.
- **Anonymous memory is the figure that decides whether the application survives**, because those
  pages cannot be dropped, only swapped or killed. Indexing the million-document corpus peaked at
  **1.82 GB of anonymous memory**, at both memory limits. Inside a 2 GB limit that did not fit, and
  about 660 MB of it was pushed out to the host's swap while indexing was still running. Inside a
  4 GB limit it fitted entirely, with swap at zero at the moment of the peak.

**So: 2 GB is comfortable for tens of thousands of documents and ordinary query traffic, and it is
not enough to bulk-import a million documents in one go.** The shipped default is **4 GB**, which
was measured with the anonymous peak at **46 per cent** of the limit and around 2 GB to spare, and
that is enough for a corpus of this size and shape without going higher. You can change the memory
limit at any time from the application's Resources page; nothing needs reinstalling.

**The single most useful thing you can do costs nothing.** Meilisearch merges every queued document
addition for the same index into one batch and processes it as a single unit of work. In the tests
above, up to forty-five separate twenty-thousand-document requests were merged into one batch of
**nine hundred thousand documents**, and that batch is what set the memory peak. Raising the memory
limit does not make Meilisearch merge less. So:

> When bulk importing, wait for each `documentAdditionOrUpdate` task to reach `succeeded` before
> sending the next batch. Poll `GET /tasks/<taskUid>`. Firing all your batches at once multiplies
> the peak memory by however many batches happen to be waiting.

Measured both ways on the same data inside a 2 GB limit: letting thirty-seven batches merge peaked
at **1.85 GB** of anonymous memory, while sending them one at a time peaked at **1.31 GB** and used
a fifth as much swap. Serialising is about three times slower per document, so it is a trade rather
than a free win, but it is the difference between an import that fits and one that does not. Note
also that a single twenty-thousand-document batch still wants over 1.3 GB on its own, so client
discipline alone does not make a 2 GB instance comfortable for a corpus this size. At the shipped
4 GB limit the discipline stops being load-bearing for a corpus of this size and becomes what it
should be, a way to keep headroom for everything else the application is doing.

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
(`--upgrade-db`) when the installed data store is older than the new binary.

**What is proven, and what is not.** Backup while idle, backup under heavy indexing churn, an
in-place restore, a clone from the same backup artefact, and a rollback restore onto a newer live
store have all been exercised against a real Cloudron and are recorded with their evidence in
`docs/DEBUGGING.md`. So has the dump import path, as the fall-back when no snapshot is present.
**A real cross-version `--upgrade-db` format migration has not been exercised**, because no
Meilisearch release newer than the packaged 1.51.0 existed at packaging time. The migration branch
has only been driven by forcing the version marker backwards, which proves the branch is taken, the
supervised process is started, the health check stays satisfied throughout, and the marker is
rewritten afterwards, but it does not prove that a genuine format migration completes correctly.
Treat the first upstream version bump as the test of that path, and keep the pre-update backup.

One known defect is carried deliberately. If a restore has to fall back to importing a dump, the
import is a full re-index and can take much longer than the entrypoint's 300-second health wait; on
a 680 000-document dump it took about seven minutes. Nothing is lost, the shortfall is logged
loudly, and the next restart repairs the version marker by itself, but the first boot after such a
restore will log a warning. Raise `MEILISEARCH_HEALTH_TIMEOUT` in `/app/data/env` if you expect a
large dump import. See `docs/PACKAGING-NOTES.md` for what is verified versus assumed, and
`docs/decisions/` for the full reasoning behind each of these choices.

## Documentation

- `docs/decisions/` carries the numbered architecture decision records behind this package.
- `docs/PACKAGING-NOTES.md` is the anonymised, verified-versus-assumed log for this package.
- `docs/FOR-CLOUDRON.md` carries platform observations offered back to the Cloudron team.
- `docs/FOR-UPSTREAM.md` carries packaging observations offered back to the Meilisearch team.
- `docs/DEBUGGING.md` is the runbook, including the gate evidence tables.
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
