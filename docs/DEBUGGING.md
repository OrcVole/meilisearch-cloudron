# Debugging

A runbook for diagnosing this package on Cloudron. It is written so that an agent with only the
repository and the logs can find and fix a failure. When you fix a new failure, add it to "Known
failures" with the symptom, the cause, and the fix.

Gates 0, 1 and 2 have run on a real box against the shipping digest and their tables below carry
real evidence. Gates 3 and 4 have not, apart from two rows settled early. Do not fill a gate row
with anything that was not actually observed on a running box; local findings go in "Invariants
proven locally" instead.

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

### Gate 3: update and restore

Not run. One Gate 3 precondition was settled early, because it was cheap and it decides whether
the leg 3 design is safe on a real platform at all.

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

The one residual risk, stated honestly: the port is free for under a second between the supervised
process stopping and the final `exec`. The platform polls every 10 seconds, so a poll can land in
that gap. It did not here, and a single miss would not be enough on its own, but that is the only
part of the window that is not proven safe.

| Check | Expected | Evidence |
|---|---|---|
| In-place restore | Data and master key survive | not yet run |
| Clone restore (empty `persistentDirs`) | Snapshot or dump imports; data present | not yet run |
| Rollback restore | Newer store moved aside; matching snapshot imported | not yet run |
| Backup while indexing | Backup completes without corrupting the live index | not yet run |

### Gate 4: memory

| Check | Expected | Evidence |
|---|---|---|
| cgroup memory at idle | Recorded | 2026-07-31, empty store, no traffic: `memory.current` 30 896 128 bytes, `memory.peak` 32 083 968 bytes, `memory.max` 2 147 483 648 bytes. That is 1.4 per cent of the limit |
| cgroup RSS at idle | Recorded | not yet run |
| cgroup RSS during bulk indexing of a realistic corpus | Recorded, with the corpus described | not yet run |
| Swap usage during indexing | Recorded | not yet run |

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
