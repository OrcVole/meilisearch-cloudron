# Debugging

A runbook for diagnosing this package on Cloudron. It is written so that an agent with only the
repository and the logs can find and fix a failure. When you fix a new failure, add it to "Known
failures" with the symptom, the cause, and the fix.

All five gates have now run on a real box against the shipping digest, and every table below carries
real evidence. Gates 0 to 3 PASS; Gate 4 FAILS on sizing and recommends a larger `memoryLimit`. Do
not fill a gate row with anything that was not actually observed on a running box; local findings go
in "Invariants proven locally" instead.

## State on disk (where to look first)

- `/app/db/data.ms` is the Meilisearch data store, on the `persistentDirs` path. It never enters
  the ordinary `/app/data` backup file walk.
- `/app/db/.meili-version` is the boot-time version marker: a single line, the version of the
  binary that last reached a healthy start. It is written only after `/health` answers, so it never
  claims a version that failed to open the store.
- `/app/db/quarantine-<UTC timestamp>/data.ms` is a data store moved aside by leg 3 or leg 4. It is
  never deleted immediately; boot-time pruning removes it after 30 days.
- `/app/data/master-key` holds the generated master key, mode 0600, owner `cloudron`.
- `/app/data/snapshots/data.ms.snapshot` is the snapshot. Meilisearch always writes that one name
  and overwrites it in place, at mode 0444, so there is normally exactly one.
- `/app/data/dumps/*.dump` holds dumps, if any have been created. Nothing creates one
  automatically; the package only imports them.
- `/app/data/.endpoint` holds this container's own address as `http://<IPv4>:7700`, rewritten on
  every boot, because the backup container has no other way to find the application.
- `/app/data/.last-backup.log` holds one line per backup attempt, newest last, trimmed to 100
  lines. It is the only durable record of a backup run: the backup container's stdout is discarded
  by the platform.
- `/app/data/env`, if the operator created it, holds override settings. See the README.

## Boot sequence

Every package-emitted line is prefixed `==> [start]`, so `cloudron logs | grep '==>'` gives the
whole boot in order. The sequence is:

1. Create and take ownership of `/app/data` and `/app/db`; re-assert 0600 on the master key.
2. Write `/app/data/.endpoint` from the first IPv4 of `hostname -I`.
3. Source `/app/data/env` if it exists.
4. Compute `MEILI_MAX_INDEXING_MEMORY` from the cgroup limit, one third, floor 256 MiB. The log
   line names the limit, its source, and whether the value was computed or overridden.
5. Generate the master key if and only if this is a genuinely first run. A store present without a
   key file is a hard stop.
6. Apply the forced settings, which overwrite anything `/app/data/env` set for them.
7. Run exactly one leg of the decision tree, and say which one:
   - `leg: 1` no store. Import the newest snapshot, else the newest dump, else start empty.
   - `leg: 2` store present, marker matches the binary. Normal start.
   - `leg: 3` marker older than the binary, or missing. Run a supervised `--upgrade-db` process to
     completion, stop it cleanly, then start normally. On failure, quarantine and import a dump.
   - `leg: 4` marker newer than the binary, meaning a rollback restore. Quarantine the store and
     import the newest snapshot.
   Legs 3 and 4 only ever quarantine a store when there is an artefact to put in its place; with
   nothing to import they stop loudly and leave the store alone.
8. Prune to the newest two snapshots and dumps, and delete quarantined stores over 30 days old.
9. Start a background poller that writes the version marker once `/health` answers.
10. `exec /usr/bin/tini -- gosu cloudron:cloudron` into the server.

A normal boot is about one second to health. A boot through leg 3 takes about 50 seconds even when
there is nothing to migrate, because the script waits a grace period to be sure no upgrade task is
coming. If a boot seems to hang, check which leg the log named before assuming a fault.

## Invariants proven locally (not gate evidence)

Observed on a local container built from this repository on 2026-07-30. These are the things that
should stay true; if one of them stops being true, something has regressed.

| Invariant | How it was shown |
|---|---|
| The build fails on a wrong binary checksum | Deliberately wrong `sha256` build argument: `1 computed checksum did NOT match`, exit 1 |
| The build fails on an unresolvable binary | `ldd` gate greps for `not found` and runs `--version` on both binaries |
| `GET /health` needs no credential; everything else does | 200 unauthenticated; `GET /version` and search both 401 without the key, 200 with it |
| Production mode serves no search preview | `GET /` returns `{"status":"Meilisearch is running"}` as `application/json`, zero HTML |
| The master key is never regenerated | Second boot logs `existing key found`; a store without a key file exits 1 with a `FATAL` line |
| The store is never destroyed to make room for an import | Legs 3 and 4 check for an artefact before quarantining, and stop loudly if there is none |
| The version marker never claims an unhealthy start | Marker written only after `/health` answers; a stop mid-upgrade left it unchanged |
| A stop is honoured in every phase | 187ms normally, about 3s during a supervised upgrade, both exit 143 |
| The backup script never exits non-zero | Exit 0 with the app up, with the app stopped, and with an empty `/app/data` |
| The package's structural settings beat `/app/data/env` | Decoy file setting `MEILI_ENV=development` and `MEILI_DB_PATH=/tmp/hijacked` had no effect on either |
| Indexing memory follows the cgroup, not the host | 1 GiB limit produced `MEILI_MAX_INDEXING_MEMORY=357913941` |

## Release-gate evidence: the shipping image (2026-07-31)

The shipping image was built from the committed tree, scanned, and pushed. These rows are real
evidence, unlike the gate tables below, but they prove the artefact, not the platform behaviour.

| Invariant | Proof |
|---|---|
| The image is built from the committed tree, not a working copy | `git archive HEAD` exported to a scratch directory, `podman build --no-cache` run there; tree hash `b953052` |
| The linkage gate passes in the shipping build | Build log: `linkage gate passed for 1.51.0`, preceded by `/tmp/meilisearch: OK` from `sha256sum -c` |
| The published artefact carries no credential shapes, box specifics or identities | `test/secret-scan.sh` over both surfaces: repository file set (26 files, one allowlisted sanctioned `contactEmail` line) and the image filesystem (`/app /etc /root /home /usr/local /opt`), exit 0, `secret-scan OK` |
| The base image's inert SSH host keys are the pinned ones and nothing else | Image scan: `host keys: 3 found, 3 pinned-ok, 3 expected`, each `pinned-ok` by exact sha256 |
| The registry digest is what the manifest pins | `skopeo inspect --format '{{.Digest}}' docker://ghcr.io/orcvole/meilisearch-cloudron:1.51.0-1` returns `sha256:13726db11bd9545985ae5e98f6efb9ada660bcdd87958d827e085328389e842e`, which is the `dockerImage` value |

**Trap worth remembering: podman's local `RepoDigests` after a push can name a manifest the
registry does not have.** Immediately after `podman push`, `podman image inspect --format
'{{json .RepoDigests}}'` reported
`ghcr.io/orcvole/meilisearch-cloudron@sha256:476bd0e18189...`, and pulling that digest from the
registry fails with `manifest unknown`. The registry's own answer for the same tag is
`sha256:13726db11bd9...`. The local value is the digest of the locally stored manifest, which is
not necessarily the one the registry ended up storing. Always resolve the digest to pin with
`skopeo inspect` against the registry, never from the local image record. Pinning the local value
would have produced a manifest whose `dockerImage` no client can ever pull.

## Gate evidence tables

Gates 0, 1 and 2 ran on 2026-07-31 against the shipping digest
`sha256:13726db11bd9...`, on a real Cloudron box, over the public HTTPS hostname rather than
localhost, so the reverse proxy and TLS are part of what passed. Gates 3 and 4 are still unrun.

### Gate 0: install and first boot. PASS

| Check | Expected | Evidence |
|---|---|---|
| Test what you ship | Installed digest equals the manifest `dockerImage` | Install output `Using image ...@sha256:13726db11bd9...`; `cloudron status` reports the same digest |
| Container starts, no restart loop | One boot per deliberate operation, health green | Exactly three `==> [start] Meilisearch 1.51.0 booting` lines across install, a deliberate restart and a deliberate leg 3 restart. No `unhealthy`, no platform-initiated restart, no `Exited` in the log |
| Boot is fast | Health well within the platform timeout | First boot `booting` at 00:07:02Z, `Server listening on 0.0.0.0:7700` at 00:07:06Z, first `/health` 200 at 00:07:07Z: **5 seconds**. The platform's own `Wait for health check` step passed on the first poll |
| Health check satisfied continuously | Platform poller always 200 | `Mozilla (CloudronHealth)` `GET /health status_code=200` every 10 seconds without exception, from 00:07:20Z onward |
| `healthCheckPath` open unauthenticated | 200 with no credential, from outside the box | `GET /health` over public HTTPS, no header: `http=200`, body `{"status":"available"}` |
| Master key generated correctly | mode 0600, owner cloudron, 64 hex | `600 cloudron:cloudron 65 /app/data/master-key`, content 64 characters, file sha256 `bed6e834...` |
| Master key idempotent across restart | Same hash, existing-key branch taken | After `cloudron restart`: `master key: existing key found at /app/data/master-key`, `leg: 2, store written by 1.51.0, matching this binary, normal start`, sha256 still `bed6e834...` |
| Store created on the persistent path | `/app/db/data.ms` exists, owned cloudron | `drwxr-xr-x cloudron cloudron /app/db/data.ms` containing `VERSION` and `auth/` |
| Endpoint file written with a reachable IPv4 | Address matches what the platform itself routes to | `/app/data/.endpoint` = `http://172.18.16.57:7700`, mode 0640 cloudron:cloudron. The container has exactly one global IPv4 (`eth0 172.18.16.57/16`) alongside one global IPv6, and the platform's own nginx config for this app names `"ip":"172.18.16.57"`. `curl $(cat .endpoint)/health` from inside returns 200 |
| Version marker written only after health | Marker timestamp later than first health 200 | First health 200 at 00:07:07Z, `marker : healthy, /app/db/.meili-version now records 1.51.0` at 00:07:08Z; file content `1.51.0` |
| Indexing memory from the manifest, not host RAM | `2147483648 / 3 = 715827882` | Boot log `limit 2048 MiB from cgroup v2 memory.max; indexing memory 682 MiB (limit / 3, floor 256 MiB)`; PID 1 environment carries `MEILI_MAX_INDEXING_MEMORY=715827882`; `/sys/fs/cgroup/memory.max` reads `2147483648` |
| Process tree is as designed | tini as PID 1, server as the cloudron user | `1 0 root /usr/bin/tini -- gosu cloudron:cloudron /app/code/meilisearch`, `50 1 cloudron /app/code/meilisearch` |
| Production mode forced | `Environment: "production"`, store path not overridable | Startup banner `Environment: "production"`, `Database path: "/app/db/data.ms"` |

Idle memory at rest, for Gate 4's baseline: `memory.current` 30 896 128 bytes, `memory.peak`
32 083 968 bytes, against a 2 147 483 648 byte limit.

### Gate 1: auth. PASS

Every request below went over the public HTTPS hostname.

| Check | Expected | Evidence |
|---|---|---|
| `GET /health` with no key | 200 | `http=200`, `{"status":"available"}`, while a master key is set |
| `GET /version`, `/indexes`, `/keys`, `/stats`, `/tasks` with no key | 401 | All five `http=401` with `"code":"missing_authorization_header"` |
| The same five routes with the master key | 200 | All five `http=200`; `/version` reports `pkgVersion 1.51.0` |
| Root path in production mode | JSON, no search preview UI | `GET /` `http=200`, `content-type: application/json`, body `{"status":"Meilisearch is running"}`, zero matches for `<html`, `<!doctype`, `<script`, `<body` |
| Default keys exist | Search and Admin present with correct scopes | `GET /keys` `total: 4`: `Default Search API Key` (`actions:["search"]`), `Default Admin API Key` (`actions:["*"]`), `Default Read-Only Admin API Key` (`actions:["*.get","keys.get"]`), `Default Chat API Key` (`actions:["chatCompletions","search"]`), all `indexes:["*"]`, none expiring |
| The default search key behaves to its scope | Search yes, write no, key listing no | Search on two indexes `http=200` with hits; `POST /indexes` `http=403 invalid_api_key`; `GET /keys` `http=403 invalid_api_key` |
| A minted key scoped to one index cannot read another | 403 on the other index | `POST /keys` `http=201` for `{"actions":["search"],"indexes":["alpha"]}`; search on `alpha` `http=200` returning `["alpha secret"]`; search on `beta` `http=403` with `The API key cannot acces the index 'beta', authorized indexes are ["alpha"]`; `GET /indexes` and `POST /indexes` both `http=403` |

### Gate 2: functional flows. PASS

Corpus: six documents with `title`, `overview`, `genre`, `year`, in an index `gate2` with
`primaryKey: "id"`.

| Check | Expected | Evidence |
|---|---|---|
| Create index | Task succeeds | `POST /indexes` `http=202`, task 4 `indexCreation succeeded` |
| Update settings | Settings readback matches | `PATCH /indexes/gate2/settings` task 5 `succeeded`; readback shows `searchableAttributes ["title","overview"]`, `filterableAttributes ["genre","year"]`, `sortableAttributes ["year"]`, `minWordSizeForTypos {oneTypo:4,twoTypos:8}` |
| Add documents, exact count | 6 in, 6 stored | Task 6 `succeeded`; `numberOfDocuments: 6`, `isIndexing: false`, `fieldDistribution` 6 for every one of the five fields |
| Document round trip is byte identical | Same sha256 in and out | Document 1 as sent, sorted keys, sha256 `8def79e8...`; `GET /indexes/gate2/documents/1` sorted the same way, sha256 `8def79e8...`, `cmp` reports identical |
| Search finds an exact term | Correct single hit | `q=vole` returns `["The Orkney Vole"]`, `estimatedTotalHits 1` |
| Typo tolerance | Misspellings still match | `q=puffn` returns `["Puffin Colony"]`; `q=neolthic` returns `["Standing Stones"]` (matching the `overview` field, one typo in an eight-letter word) |
| Filter narrows correctly | Exact subset | `filter=genre = history` returns `["Standing Stones","The Longship"]`, total 2; `filter=year > 1960 AND genre = drama` with `sort=year:desc` returns only `Selkie Song` (1999) |
| Partial update | Only the named field changes | `PUT /indexes/gate2/documents` with `{"id":3,"genre":"noir"}` task 7 `succeeded`; document 3 readback keeps `title` and `year`, `genre` is now `noir`; `filter=genre = noir` returns `["Harbour Lights"]` |
| Delete one document | Count drops by exactly one | `numberOfDocuments` 6 then 5, delta 1; `q=selkie` returns 0 hits |
| Delete index | Index gone | Task 9 `succeeded`; `GET /indexes/gate2` `http=404 index_not_found` |
| Integration leg, experiment X3 | A real consumer's call sequence returns search results | See the table below |

**Integration leg (X3): LibreChat's own call sequence, driven from a throwaway client.** The
sequence was read out of LibreChat's source rather than guessed, and driven with the same client
library at the version LibreChat pins (`meilisearch@0.38.0`), from a scratch Node project on the
workstation against the test install's public hostname. No LibreChat instance was touched.

| Step, as LibreChat makes it | Evidence |
|---|---|
| `client.health()` (its `/api/search/enable` probe) | `{"status":"available"}` |
| `index.getRawInfo()` on a first boot | `index_not_found`, the branch that triggers creation |
| `client.createIndex('convos', {primaryKey:'conversationId'})` then `waitForTask` | task 10 `succeeded` |
| `client.createIndex('messages', {primaryKey:'messageId'})` then `waitForTask` | task 12 `succeeded` |
| `index.updateSettings({filterableAttributes:['user']})` on both | tasks 11 and 13 `succeeded` |
| `index.addDocuments(docs, {primaryKey})` on both | tasks 14 and 15 `succeeded`, 3 documents each |
| `index.search(q, {filter: 'user = "<id>"'})`, the search the app actually runs | `convos.search('vole')` returns `["Orkney vole taxonomy"]`; `messages.search('vole')` returns `["m-bbb-1"]` |
| Typo tolerance through the same path | `messages.search('cloudrn manifst')` returns `["m-aaa-1"]` |
| Per-user isolation through the `user` filter | 0 documents belonging to another user in any filtered result; the other user's own filter returns only their own document |
| `index.getDocument(id)` | returns `"Packaging Meilisearch for Cloudron"` |
| `index.deleteDocument(id)` | task 16 `succeeded`; `GET` on that id afterwards `http=404 document_not_found`, and the search that used to return it returns 0 hits |

The keyed search path is proven end to end: every call above carried the master key, the way
LibreChat carries `MEILI_MASTER_KEY`, and every one succeeded through the public hostname.

### Gate 3: update and restore. PASS

Run 2026-07-31 against the shipping digest, on a throwaway test install carrying the Gate 1 and
Gate 2 fixtures plus a one-million-document corpus. Five legs, all passing. The clone was torn
down afterwards.

**The corpus, because every number below depends on it.** Deterministically generated (seed
`20260731`), not downloaded: 1 000 000 documents in 50 NDJSON batches of 20 000, 401 705 492 bytes,
fields `id`/`title` (5 words)/`body` (28 words)/`genre` (8 values)/`author` (20 000
values)/`year`/`rating`, over a synthetic 200 000-token Zipf vocabulary, with `genre`, `author` and
`year` filterable and `rating`/`year` sortable. A large vocabulary makes the corpus harder to index
than real prose of the same size, which is the right direction for a sizing test. It produced a
**4 590 416 518-byte store, 11.4× the raw input.**

#### Leg 1, backup while idle

| Check | Expected | Evidence |
|---|---|---|
| The platform runs the `backupCommand` | A status line appears | `/app/data/.last-backup.log` did not exist beforehand; afterwards it held `2026-07-31T00:45:43Z succeeded snapshot task 17 completed`. That file is the only channel out of the temp container, whose stdout is discarded |
| The snapshot task ran on the live app | `snapshotCreation succeeded` | Task 17, `succeeded`, `duration PT0.119526448S`, `enqueuedAt 00:45:38.504Z`. The instance had never created a snapshot before this run |
| An artefact lands inside the backed-up tree | file in `/app/data/snapshots` | `data.ms.snapshot`, 22 884 bytes, `-r--r--r-- cloudron:cloudron`, sha256 `29778f66f7f4…` |
| Cost | Small | `cloudron backup create --app …` took **28.5 s** end to end (00:45:27Z → 00:45:55Z) |

#### Leg 2, backup under churn (the leg that justifies `persistentDirs`)

Backup issued at 00:51:56Z with **16 tasks enqueued** and `"isIndexing":true`.

| Check | Expected | Evidence |
|---|---|---|
| The backup run completes and does not error | clean run | `app <test install> backup finished. Took 314.553 seconds`, then `App is backed up`, exit 0. No syncer error |
| The snapshot task succeeds inside the 600 s poll | `succeeded` | Task 50: enqueued 00:52:09.44Z, **started 00:52:25.33Z**, finished 00:56:26.94Z, `duration PT241.609397690S`. **241 s of the 600 s budget** |
| The `backupCommand` records it | one line | `2026-07-31T00:56:28Z succeeded snapshot task 50 completed` |
| The artefact is real | large file | 515 968 019 bytes, uploaded by the platform at 5–14 MB/s |
| Indexing is not disturbed | zero failures | Zero failed tasks; the queue kept draining and reached 1 000 000 documents at 01:07:37Z; `/health` 200 at every probe throughout |
| Nothing accepted before the snapshot point is lost | count decomposes exactly | The clone of this backup (leg 4) converged to **680 000** `corpus` documents = 260 000 committed at the consistency point + 420 000 carried as undrained task payloads inside the snapshot. The 320 000 absent are the batches accepted *after* 00:52:25Z |

**Non-obvious and load-bearing: a Meilisearch snapshot carries the task queue with its undrained
document payloads, so a restore resumes the indexing that was in flight.** A backup taken mid-bulk-
index is complete, not merely consistent. The consistency point is when the snapshot *task starts*,
not when the backup was requested (16 s apart here).

#### Leg 3, in-place restore

`cloudron restore --app <test install> --backup <churn backup>`, 01:24:08Z → 01:26:01Z,
**1 m 53 s**, `App is restored`.

| Invariant | Expected | Evidence |
|---|---|---|
| Master key byte-identical | same sha256 | `bed6e83442762f05…` before and after, unchanged since Gate 0 |
| Master key mode and owner re-asserted | `600 cloudron:cloudron` | `600 cloudron:cloudron 65 /app/data/master-key` after the post-restore boot |
| Restore does reset modes | it does | `data.ms.snapshot` came back `-rw-r--r--`; Meilisearch writes it `0444`. `.last-backup.log` came back `cloudron:cloudron` having been written `root:root` by the temp container, because `start.sh` does `chown -R` on every boot. The re-assertion is required, not defensive |
| Every derived key still works | scoped key returns its hit | `gate1-alpha-only` returned `{"id":1,"title":"alpha secret"}` |
| Data intact | counts exact | `alpha` 1, `beta` 1, `convos` 2, `messages` 3, `corpus` 1 000 000 |
| The live store may be NEWER than the restored `/app/data` | `persistentDirs` preserved | Live `/app/db` still held 1 000 000 documents while the restored `/app/data` snapshot's consistency point held 260 000. Confirmed exactly |
| Boot path | existing store, existing key | `leg : 2, store written by 1.51.0, matching this binary, normal start`; `master key: existing key found`; `marker : healthy` 3 s after `booting` |
| Outage | platform window only | Independent 1-second poll: 200 until 01:24:18Z, one 502 at 01:24:19.2Z, refused until 01:25:54Z, 200 from 01:25:56.2Z. **97 s**, all container teardown and recreate |

#### Leg 4, clone to a new location (empty `persistentDirs`)

`cloudron clone --app <test install> --backup <churn backup> --location
<clone location>`, 01:30:07Z → 01:32:51Z, **2 m 43 s**.

| Check | Expected | Evidence |
|---|---|---|
| `persistentDirs` start EMPTY | leg 1, not leg 2 | `leg : 1, no store present, rebuilding from the newest artefact`; `version : 1.51.0 (marker was 'none')`. The same backup restored in place took leg 2, so both semantics are demonstrated from one artefact |
| The boot tree rebuilds from `/app/data` | snapshot import | `import : newest snapshot /app/data/snapshots/data.ms.snapshot`; `exec : meilisearch --import-snapshot … --ignore-missing-snapshot` |
| Import cost | fast | `booting` 01:32:31Z → `marker : healthy` 01:32:50Z: **19 s for a 516 MB snapshot** |
| Documents searchable in the clone | hits | `q=liekou` with `filter=genre = drama` returned hits; `corpus` 680 000, `alpha` 1, `beta` 1, `convos` 2, `messages` 3 |
| The master key travels in `/app/data` | scoped key works | `gate1-alpha-only`, minted on the original, returned its hit against the clone |
| Torn down | gone | `App <clone location> successfully uninstalled`; one `meili` row in `cloudron list`; the hostname no longer answers |

#### Leg 5, the dump path (previously unexercised code)

Run on the clone. Dump created, then the snapshot and the whole store deleted so only the dump
remained.

| Check | Expected | Evidence |
|---|---|---|
| A dump can be created | `dumpCreation succeeded` | Task 54, `dumpUid 20260731-013801980`, `duration PT68.474096503S`, file **83 067 397 bytes for 680 015 documents** (a dump is documents and settings, not an index: an eighth of the snapshot's size) |
| The boot tree falls through to the dump | `--import-dump` | `import : no snapshot found, newest dump /app/data/dumps/20260731-013801980.dump`; `exec : meilisearch --import-dump … --ignore-missing-dump` |
| The documents return | counts and search | `corpus` 680 000 searchable with filter and sort; `alpha` 1, `beta` 1, `convos` 2, `messages` 3; `gate1-alpha-only` still returns its hit; rebuilt store 2 378 777 222 bytes |
| **A dump import is a full re-index and can outrun the marker wait** | defect, see below | `exec` 01:41:51Z, healthy about 01:48:50Z: **roughly 7 minutes**. `start.sh` logged `WARNING: no healthy response within 300s; /app/db/.meili-version was left unchanged`, and the marker file was absent |
| The missing marker self-heals | leg 3 no-op writes it | Next restart: `leg : 3, store present with no version marker, treating as possibly older` → `no upgradeDatabase task was enqueued` → marker back to `1.51.0`. Cost: one 26-second boot |

**Open defect.** `MEILISEARCH_HEALTH_TIMEOUT` defaults to 300 s, which was sized against a normal
boot and not against a dump import of an arbitrary corpus. The behaviour is fail-safe (it refuses
to record a version it never saw become healthy), loud, and self-healing, and an operator can raise
the timeout in `/app/data/env` without a rebuild — but the correct fix is to keep waiting while the
server process is alive rather than run a fixed clock. Only a restore that has lost its snapshot
reaches this path.

#### The leg 3 health window, and the residual race

**Does the platform's health checker tolerate the leg 3 window? Yes, comfortably.** Provoked on
2026-07-31 by writing `1.50.0` into `/app/db/.meili-version` on a test install and restarting.

| Check | Expected | Evidence |
|---|---|---|
| Leg 3 is entered | Log names leg 3 | `leg : 3, store written by 1.50.0, older than 1.51.0, upgrading` |
| The platform accepts the app as healthy during the supervised upgrade | `Wait for health check` passes immediately | `cloudron restart` returned `App restarted` 17 seconds after it was issued, while the supervised upgrade was still running (it did not finish for another 23 seconds) |
| No platform-initiated restart during the window | Exactly one boot | One `booting` line for this restart, and the only `Restarting container` line is the deliberate task. No `unhealthy` line anywhere |
| Every platform health poll during the window answered | All 200 | `Mozilla (CloudronHealth)` polls at 00:29:30, 00:29:40, 00:29:50, 00:30:00, 00:30:10Z, all `status_code=200`. The 00:29:50 poll landed in the same second as `stopping the supervised process` |
| An external observer sees no outage | Continuous 200 | An independent 2 second poll of the public hostname recorded 200 throughout, with a single 502 at 00:29:28Z during container teardown, before `start.sh` ran at all |
| The window is shorter on the box than locally | About 51s locally | **26 seconds** here: `booting` 00:29:27Z to `marker : healthy` 00:29:53Z, of which the no-task grace period was 23 seconds |
| Data and credentials survive leg 3 | Unchanged | Index document counts identical before and after (`alpha` 1, `beta` 1, `convos` 2, `messages` 3); a scoped key minted before the restart still returns its hit; master key sha256 still `bed6e834...`; marker advanced to `1.51.0`; zero quarantine directories |

The residual risk was that the port is free for under a second between the supervised process
stopping and the final `exec`, against a platform poll every 10 seconds. That was sampled properly
on 2026-07-31 and the section below records the result.

**Result: five leg 3 cycles, zero hits, and the platform turns out to drop polls by itself
anyway.**

Detection method, which is the part worth reusing: a platform poll that lands while the port is
free never reaches the application, so it leaves **no line at all** in the app log. It cannot be
found by looking for a failure; it is found as a **gap in the otherwise exact 10-second
`Mozilla (CloudronHealth)` cadence**. An external poller cannot do this job at all — a 1- or
2-second poll cannot see a sub-second hole, and it is not the observer that can restart the
container.

| Cycle | Boot → healthy | Supervised stop | Poll before / after the stop | Lost polls, and where |
|---|---|---|---|---|
| A | 01:50:43 → 01:51:09 (26 s) | 01:51:06 | 01:51:00 **200** / 01:51:10 **200** | 1, at 01:50:40, during container teardown |
| B | 01:59:04 → 01:59:30 (26 s) | 01:59:27 | 01:59:20 **200** / 01:59:30 **200** | 1 at 01:59:00 (teardown); 1 at 01:53:30 unrelated, see below |
| C | 02:01:33 → 02:02:01 (28 s) | 02:01:57 | 02:01:50 **200** / 02:02:00 **200** | 3, 02:01:10–02:01:30, all teardown |
| D | 02:05:58 → 02:06:27 (29 s) | 02:06:23 | 02:06:20 **200** / 02:06:30 **200** | 3, 02:05:40–02:06:00, all teardown |
| E | 02:13:38 → 02:14:07 (29 s) | 02:14:03 | 02:14:00 **200** / 02:14:10 **200** | 3 at teardown; 1 at 02:14:20, **after** the app was already serving |

**Zero of five cycles lost a poll to the supervised-stop window.** In every cycle the polls
bracketing the stop, ten seconds apart, both returned 200, and no cycle produced an `unhealthy`
line, an extra `booting` line, or a platform-initiated restart. A sixth restart (with the marker
left alone) ran leg 2 in 3 seconds as a control and behaved identically.

**The stronger safety result is the accidental one: the platform loses polls on a healthy app and
nothing happens.** Two isolated single-poll losses were recorded with the application demonstrably
up — at 01:53:30, where an independent 1-second external poll got 200 straight through it, and at
02:14:20, where the app's own log shows it answering the polls at 02:14:10 and 02:14:30 either side.
So a single missed poll is not diagnostic of anything, and the platform evidently does not act on
one. That is a better argument for the leg 3 design than five clean cycles, because it does not
depend on the sub-second window never being hit.

Honest limit of this evidence: the gap is well under one second against a ten-second period, so a
per-cycle hit probability below ten per cent is entirely consistent with five clean cycles. **This
sampling does not prove the window can never be hit.** It proves the window was not hit in five
tries, and that being hit once would not matter.

| Check | Expected | Evidence |
|---|---|---|
| The supervised-stop gap is lost-poll-free | no gap straddles the stop | 5 of 5 leg 3 cycles; polls either side of the stop all 200 |
| Losing a poll is survivable anyway | no reaction | 2 isolated losses on a healthy serving app, no `unhealthy` line, no restart, no quarantine directory |
| The window is stable at scale | ~26 s regardless of store size | 26–29 s across five cycles against a **4.6 GB** store, versus 26 s previously against a near-empty one. The 20-second no-task grace dominates it; the store size does not |

### Gate 4: memory. FAIL on sizing (no OOM kill)

Load: the same one-million-document corpus described under Gate 3, pushed as 50 requests of 20 000
documents as fast as the link allowed, so a deep queue built up. Sampler ran inside the container
every 3 seconds for 30 minutes (544 samples). cgroup v2 counters are readable from inside a Cloudron
app container, so this gate needs no root shell on the host.

`memory.peak` needed no reset: it stood at 38 547 456 before the load, barely above idle.

| Counter | Idle | Loaded (peak) | At rest afterwards, 4.6 GB store |
|---|---|---|---|
| `memory.current` | 35 872 768 | **2 147 483 648**, exactly `memory.max` | 2 023 395 328 |
| `memory.peak` | 38 547 456 | **2 148 102 144** = 100.03 % of the 2 GiB limit | — |
| `memory.stat anon` | ~24 MB | **1 981 636 608** (1.85 GiB) | 608 825 344 |
| `memory.stat file` (page cache of the mapped store) | ~10 MB | 1 971 851 264 | 1 365 684 224 |
| `memory.stat slab` | ~4 MB | 35 337 368 | ~15 MB |
| `meilisearch` RSS | ~26 MB | **2 102 996 KiB = 2.006 GiB** | 1 618 528 KiB |
| `meilisearch` VSZ | ~10 TiB | **10 765 870 632 KiB = 10.02 TiB** | 10.02 TiB |
| `memory.swap.current` | 0 | ≥ 661 164 032 observed | 581 488 640 |
| `memory.events oom_kill` | 0 | **0** | 0 |
| `memory.events max` (reclaim at limit) | 0 | **30 867** | — |
| `pgmajfault` / `workingset_refault_anon` | 18 / 0 | 94 070 / 165 068 | — |
| `memory.pressure full avg10` | 0 | 18.04 | ~0 |

**Which figure matters, and why the other two mislead in opposite directions.**

- **VSZ is meaningless.** 10.02 TiB is the LMDB map size the process reserves as address space. It
  is not memory and implies nothing about memory. Any sizing argument using it is arithmetic on a
  number with no physical referent. (Experiment X5, confirmed on the box.)
- **`memory.current` at the cap is not danger.** It sat at the limit for 308 of 544 samples and
  still sits at 94 per cent at rest with the app idle, because most of it is `file`: clean,
  reclaimable page cache backing the memory-mapped store. Any store larger than `memoryLimit` will
  do this. An operator reading the dashboard graph will think the app is broken; it is not.
- **`memory.stat anon` decides survival.** Anonymous pages cannot be dropped, only swapped or
  killed. Peak 1.85 GiB inside a 2 GiB cap, with at least 661 MB simultaneously in host swap:
  **about 2.5 GiB of anonymous demand against a 2 GiB limit.**

| Check | Expected | Result |
|---|---|---|
| `oom_kill` zero, app healthy, load verifiably landed | yes | **PASS**: 0 kills; `/health` 200 at every probe across 30 minutes; 1 000 000 documents indexed, zero failed tasks, searches with filter and sort return hits |
| loaded `memory.peak` at or below 80 per cent of `memoryLimit` | ≤ 1.72 GiB | **FAIL**: 2 148 102 144, 100.03 per cent |
| worst-case bound clears `memoryLimit` with real margin | several hundred MB spare | **FAIL**: anonymous demand alone was about 2.5 GiB |

**Why it survived, and why that is not reassuring.** `memory.swap.max` inside the container is
`max` and the host had swap available, so about 661 MB of anonymous memory was written out and
faulted back 165 068 times rather than the OOM killer firing. **On a host without swap the same run
had nowhere to put those pages.** `oom_kill == 0` is a much weaker pass signal than it looks.

**Cause: auto-batching, not corpus size.** `GET /batches` during the run showed batch uid 24 with
`"totalNbTasks":37` and `"receivedDocuments":740000`. Thirty-seven separate 20 000-document requests
were merged by Meilisearch into a single 740 000-document unit of work; queue depth froze at 37 and
`numberOfDocuments` froze at 260 000 for nine minutes, then jumped to 1 000 000 when that one batch
committed. **Peak memory tracks the batch Meilisearch chooses, not the request the client sent nor
the size of the corpus.**

`MEILI_MAX_INDEXING_MEMORY` was 682 MiB throughout (`limit / 3`, logged every boot) while anonymous
memory reached 1.85 GiB. **The divide-by-three is not a ceiling on the process.** It caps one
indexer buffer, not per-thread structures across 12 cores, the merge phase, or the write buffers.

**Controlled counterpart: the same batches, indexed one at a time.** 200 000 documents were then
sent as ten 20 000-document batches into a fresh index, with the client waiting for each
`documentAdditionOrUpdate` task to reach `succeeded` before sending the next, so Meilisearch never
had more than one task to merge. Tasks 71 to 80, all `succeeded`, 08:14:46Z to 08:26:57Z.

| | Deep queue (37 tasks merged into one 740 000-document batch) | Strictly serialised (one 20 000-document batch at a time) |
|---|---|---|
| peak `memory.stat anon` | **1 981 636 608** (1.85 GiB) | **1 409 392 640** (1.31 GiB) |
| `memory.swap.current` | ≥ 661 164 032 | 135 430 144 |
| `oom_kill` | 0 | 0 |
| throughput | ~740 000 docs in ~15 min | 200 000 docs in 12 min |

Serialising cuts the anonymous peak by about **29 per cent** and swap traffic by about **80 per
cent**, and it costs throughput: roughly 3.6 s per thousand documents against 1.2 s when Meilisearch
is allowed to merge. **But it does not make the batch cheap.** A single 20 000-document batch still
wants over 1.3 GiB of anonymous memory, which is why 2 GiB is tight even for a perfectly
well-behaved client, and why the recommendation below is to raise the limit rather than to rely on
client discipline alone.

(`memory.peak` is useless as a comparison for this run: merely opening a store this size fills the
cgroup to the cap with reclaimable page cache within two minutes, with `anon` at 12 MB. `anon` is
the only figure that distinguishes the two runs.)

**Disk, recorded because nobody guesses it right:** 401 705 492 bytes of NDJSON became a
4 590 416 518-byte store, **11.4×**. Plan disk at roughly twelve times the corpus.

**Verdict and recommendation.** Gate 4 FAILS. It is a manifest-value failure, not a package defect:
`memoryLimit` is a manifest field, so fixing it needs no rebuild and does not invalidate the digest
gates 0 to 3 passed against. Recommended `memoryLimit` **4 GiB (`4294967296`)**: observed demand
about 2.5 GiB, divided by 0.7, rounded up to the next sensible step. Keep the divide-by-three as the
default split (it raises the indexer budget to 1365 MiB automatically) but stop describing it as a
bound. **Gate 4 must be re-run at the new limit before the value is treated as proven.** Not changed
unilaterally by the gate session; the operator decides.

## Known failures

Format: Symptom / Cause / Fix.

**`cloudron install --image ...@sha256:...` fails with `Unable to pull image ... statusCode: 401`.**
Cause: the container registry package is still private. The platform pulls the image with its own
Docker daemon, and the `cloudron` CLI has no flag for registry credentials, so a private package
cannot be installed by digest no matter how the CLI session is authenticated. Observed on
2026-07-31 against `ghcr.io/orcvole/meilisearch-cloudron@sha256:13726db11bd9...`: the install
reached `Downloading image` and then failed, leaving the app record in `error (pending_install)`.
Fix, in order of preference: flip the registry package to public, which is a one-time manual step
in the registry's own web interface and is required for publication anyway; or log the platform
host's Docker daemon into the registry with the token on standard input, which needs shell access
to the host; or configure registry credentials in the platform's own settings if the box version
offers them. There is no package-side fix, and no amount of retrying changes the result. Clean up
the errored app record with `cloudron uninstall` before retrying, so the location is free.

**Stopping, restarting, or updating the app takes the full grace period and ends in a kill.**
Cause: Meilisearch installs no `SIGTERM` handler, and a process running as PID 1 receives no
default signal dispositions from the kernel, so as PID 1 it ignores the signal outright. Measured
locally at a full 60 seconds of ignored `SIGTERM` followed by `SIGKILL` of a running database.
Fix: the entrypoint ends with `exec /usr/bin/tini -- gosu cloudron:cloudron ...` rather than
`exec gosu ...`. `tini` is already in `cloudron/base:5.0.0`, and upstream's own image uses it for
the same reason. If this symptom ever returns, check that line first. The same hazard applies
during the supervised upgrade phase, where `start.sh` itself is PID 1; that case is covered by a
`TERM`/`INT` trap in `start.sh` that forwards the signal, and losing that trap would reintroduce
the risk of a `SIGKILL` landing mid-migration.

**The app boots but every API key a consumer holds stops working.** Cause: the master key was
regenerated, which invalidates every key derived from it. The package is written so this cannot
happen by accident: a store present without a key file is a hard stop, not a regeneration. If it
happens anyway, the key file was replaced rather than restored. Fix: restore the original
`/app/data/master-key` from a backup; there is no way to re-derive the old keys from a new master
key.

**The boot appears to hang for about a minute after an update.** Usually not a fault. Check which
leg the log named. Leg 3 runs a supervised upgrade process and waits a grace period to be certain
no upgrade task is coming, which costs about 50 seconds even when there is nothing to migrate.

**Backups silently stop capturing a snapshot.** The backup command exits 0 by design in every
case, so a platform backup will look healthy regardless. Read `/app/data/.last-backup.log`: it
records `succeeded`, `skipped`, or `failed` with a reason and a timestamp for every attempt. A
run of `skipped` lines means the application was not reachable at backup time; a run of `failed`
lines with a missing endpoint file means it has not booted since install.

## When you are stuck

- Re-read `AGENTS.md`, especially the golden rules and the locked decisions.
- Re-read the relevant ADR in `docs/decisions/`; most failures are a conformance or topology
  mistake that was already reasoned about there.
- Reproduce locally with a local container run and a mounted data directory before blaming
  Cloudron.
- Record whatever you learn here so the next agent does not start from zero.
