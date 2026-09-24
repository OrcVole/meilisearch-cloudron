#!/bin/bash
#
# Runtime smoke gate for the Meilisearch Cloudron package. No box required: it runs the image the
# way Cloudron does (root entrypoint -> start.sh -> tini -> gosu cloudron) and asserts the package
# contract that a build-time check cannot reach.
#
# The contract this defends, in order of what would hurt most if it broke:
#
#   * THE MASTER KEY IS NEVER REGENERATED over an existing store. Every API key Meilisearch issues
#     is derived from the master key, so generating a new one against an existing store silently
#     invalidates every key every client holds. start.sh refuses to boot in that situation rather
#     than "helpfully" making a new one; this asserts both halves — a key on first run, and a
#     hard refusal when the store exists and the key file has gone.
#   * production mode, so every route except GET /health demands a key. Meilisearch's development
#     mode serves an open API, which on a public Cloudron domain is a data breach, not a warning.
#   * the store lives under /app/db, which is a persistentDirs entry SEPARATE from /app/data.
#     Two mounts, not one: /app/data holds the master key, snapshots and dumps; /app/db holds
#     data.ms itself. A smoke test that mounts only /app/data does not fail cleanly -- the boot
#     dies on a read-only rootfs with "cannot create directory /app/db", which looks like a
#     packaging bug and is really a harness bug. Model the platform, or the test lies.
#
# Usage:  test/smoke.sh [image]     (default: ghcr.io/orcvole/meilisearch-cloudron:dev)
#         ENGINE=docker test/smoke.sh   to use docker instead of podman
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

IMAGE="${1:-ghcr.io/orcvole/meilisearch-cloudron:dev}"

# --- identity guard (#188): refuse to test an image that is not this checkout's version --------
# A default tag nothing rebuilds WILL eventually hold a stale build, and every assertion below
# then passes against the wrong subject (proved on langfuse 2026-08-03: 12/12 green on a
# previous-major image). ABORT, not FAIL: once the subject is wrong, later results are meaningless.
_g_engine="$(command -v podman || command -v docker)"
_g_want=$(grep -o '"upstreamVersion"[^,]*' "$(dirname "$0")/../CloudronManifest.json" | head -1 | cut -d'"' -f4)
_g_got=$("$_g_engine" run --rm --entrypoint /app/code/meilisearch "$IMAGE" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$_g_got" ] || [ "$_g_want" != "$_g_got" ]; then
  echo "ABORT: ${IMAGE} bakes meilisearch '${_g_got:-unreadable}', manifest says '${_g_want}'." >&2
  echo "       Build from this checkout before smoking it (stale-tag trap, field guide #188)." >&2
  exit 2
fi
echo "identity: image bakes meilisearch ${_g_got}, matching the manifest"
ENGINE="${ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
NAME="meili-smoke-$$"
VOL="meili-smoke-vol-$$"
DBVOL="meili-smoke-db-$$"
PORT="${PORT:-17700}"
B="http://127.0.0.1:${PORT}"

fails=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails+1)); }

cleanup() {
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  "$ENGINE" volume rm "$VOL" "$DBVOL" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

start_app() {  # start_app <container-name>
  "$ENGINE" run -d --name "$1" \
    --read-only --tmpfs /run --tmpfs /tmp \
    -v "$VOL":/app/data \
    -v "$DBVOL":/app/db \
    -p 127.0.0.1:${PORT}:7700 \
    -e CLOUDRON=1 \
    -e CLOUDRON_APP_ORIGIN="$B" \
    "$IMAGE" >/dev/null 2>&1
}

wait_health() {  # wait_health <seconds>
  local n="$1" code
  for i in $(seq 1 "$n"); do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  return 1
}

echo "=== smoke: image=${IMAGE} engine=${ENGINE} ==="
"$ENGINE" volume create "$VOL" >/dev/null
"$ENGINE" volume create "$DBVOL" >/dev/null
start_app "$NAME" || { echo "could not start container"; exit 1; }

# 1. Health. GET /health is the one route Meilisearch leaves open, and it is healthCheckPath.
wait_health 60 && ok "GET /health returns 200 without a key" || {
  bad "never became healthy"; "$ENGINE" logs "$NAME" 2>&1 | tail -30; exit 1; }

# 2. The master key exists, is well-formed, and is 0600. Meilisearch accepts any string, so length
#    is our own guarantee of entropy rather than upstream's.
KEY=$("$ENGINE" exec "$NAME" cat /app/data/master-key 2>/dev/null | tr -d '\r\n')
[ "${#KEY}" -ge 32 ] && ok "master key present (${#KEY} chars)" || bad "master key length=${#KEY} (want >= 32)"
perms=$("$ENGINE" exec "$NAME" stat -c '%a %U:%G' /app/data/master-key 2>/dev/null)
[ "$perms" = "600 cloudron:cloudron" ] && ok "master key file is 600 cloudron:cloudron" \
  || bad "master key perms='$perms' (want 600 cloudron:cloudron)"
"$ENGINE" logs "$NAME" 2>&1 | grep -aqF "$KEY" && bad "master key leaked into the logs" || ok "no master key in the logs"

# 3. THE SECURITY CONTRACT: production mode. Every route but /health must demand a key. A 200 on
#    /indexes without a key means the API is open to anyone who can reach the domain.
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/indexes" 2>/dev/null || echo 000)
[ "$code" = "401" ] || [ "$code" = "403" ] && ok "/indexes rejects an unkeyed request (HTTP $code)" \
  || bad "/indexes returned HTTP $code without a key (expected 401/403 — is MEILI_ENV=production?)"

# 4. The key actually works, so 3 is not merely "everything is broken".
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "$B/indexes" 2>/dev/null || echo 000)
[ "$code" = "200" ] && ok "/indexes accepts the master key" || bad "/indexes rejected the master key (HTTP $code)"

# 5. A real document round-trip: index, wait for the async task, then search. This is the only
#    assertion that proves the store is writable and the engine actually works, rather than that
#    it merely answered a health probe.
curl -s -m 10 -X POST "$B/indexes/smoke/documents" \
  -H "Authorization: Bearer ${KEY}" -H 'content-type: application/json' \
  -d '[{"id":1,"title":"smoke test document"}]' >/dev/null 2>&1
hit=0
for i in $(seq 1 20); do
  r=$(curl -s -m 5 -X POST "$B/indexes/smoke/search" -H "Authorization: Bearer ${KEY}" \
        -H 'content-type: application/json' -d '{"q":"smoke"}' 2>/dev/null)
  echo "$r" | grep -q '"id":1' && { hit=1; break; }
  sleep 2
done
[ "$hit" = 1 ] && ok "document indexed and returned by search" || bad "search never returned the indexed document"

# 6. The store is at /app/db/data.ms, a persistentDirs path, NOT under /app/data. Cloudron backs
#    up both, but they are different mounts and the split is deliberate (the store is excluded
#    from the file backup in favour of snapshots). A store written to the wrong one survives no
#    restore.
"$ENGINE" exec "$NAME" sh -c 'test -d /app/db/data.ms' 2>/dev/null \
  && ok "store is at /app/db/data.ms (the persistentDirs path)" \
  || bad "no store at /app/db/data.ms"

# 7. Dropped privileges, and tini is PID 1. Meilisearch installs no SIGTERM handler of its own, so
#    without an init that forwards signals a stop waits out the full grace period and is then
#    SIGKILLed mid-write (field guide #89).
u=$("$ENGINE" exec "$NAME" sh -c 'ps -o user= -C meilisearch 2>/dev/null | head -1' 2>/dev/null | tr -d ' ')
[ "$u" = "cloudron" ] && ok "meilisearch runs as cloudron" || bad "meilisearch runs as '${u:-unknown}' (want cloudron)"
p1=$("$ENGINE" exec "$NAME" sh -c 'cat /proc/1/comm 2>/dev/null' 2>/dev/null | tr -d ' \n')
[ "$p1" = "tini" ] && ok "PID 1 is tini (signals are forwarded)" || bad "PID 1 is '${p1:-unknown}' (want tini)"

# 8. THE ONE THAT PROTECTS DATA: restart over the existing store must REUSE the master key, never
#    mint a new one. A regenerated key silently invalidates every API key every client holds.
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
start_app "$NAME" >/dev/null 2>&1
if wait_health 60; then
  KEY2=$("$ENGINE" exec "$NAME" cat /app/data/master-key 2>/dev/null | tr -d '\r\n')
  [ -n "$KEY2" ] && [ "$KEY" = "$KEY2" ] && ok "master key survived a restart unchanged" \
    || bad "master key CHANGED across a restart — every client API key would be invalidated"
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "$B/indexes/smoke" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && ok "indexed data survived the restart" || bad "index missing after restart (HTTP $code)"
else
  bad "did not become healthy after a restart over the existing store"
fi

# --- 1.2.0: the backup and restore contract (forum post 129974, field guide #311 to #313) --------
# The platform runs backupCommand in a throwaway container from the app image. On Cloudron 10 it
# shares the app's network namespace; restoreCommand runs before the app starts. Both are mimicked
# here with the same mounts, a read-only root and no CLOUDRON_* environment.
backup_now() {  # runs backup-snapshot.sh the way Cloudron 10 does, against the live $NAME
  "$ENGINE" run --rm --net "container:$NAME" --read-only --tmpfs /run --tmpfs /tmp \
    -v "$VOL":/app/data -v "$DBVOL":/app/db --entrypoint /app/code/backup-snapshot.sh "$IMAGE" >/dev/null 2>&1
}
restore_flag() {  # runs restore-flag.sh the way Cloudron does, with the app stopped
  "$ENGINE" run --rm --net none --read-only --tmpfs /run --tmpfs /tmp \
    -v "$VOL":/app/data -v "$DBVOL":/app/db --entrypoint /app/code/restore-flag.sh "$IMAGE" >/dev/null 2>&1
}
in_data() { "$ENGINE" run --rm -v "$VOL":/app/data -v "$DBVOL":/app/db --entrypoint sh "$IMAGE" -c "$1" 2>/dev/null; }
doc_count() {
  curl -s -m 5 -H "Authorization: Bearer ${KEY}" "$B/indexes/smoke/stats" 2>/dev/null \
    | grep -o '"numberOfDocuments":[0-9]*' | cut -d: -f2
}
wait_count() {  # wait_count <n>: indexing is asynchronous
  for i in $(seq 1 30); do [ "$(doc_count)" = "$1" ] && return 0; sleep 1; done; return 1
}

# 8b. A backup produces a snapshot AND a dump, and clears any earlier failure notice.
backup_now
in_data 'test -s /app/data/snapshots/data.ms.snapshot' && ok "backup wrote a snapshot" || bad "backup wrote no snapshot"
in_data 'ls /app/data/dumps/*.dump >/dev/null 2>&1' && ok "backup wrote a dump (the version-portable fallback)" \
  || bad "backup wrote no dump"
in_data 'test ! -e /app/data/BACKUP-FAILED.txt' && ok "a good backup leaves no failure notice" || bad "failure notice present after a good backup"
AT_BACKUP=$(doc_count)

# 8c. THE ROLLBACK: add documents after the backup, restore, and the count must return to the
#     backup's, not stay at the churned count. 1.1.0 kept the live store here (field guide #311).
curl -s -m 10 -X POST "$B/indexes/smoke/documents" -H "Authorization: Bearer ${KEY}" \
  -H 'content-type: application/json' \
  -d '[{"id":2,"t":"after backup"},{"id":3,"t":"after backup"},{"id":4,"t":"after backup"},{"id":5,"t":"after backup"}]' >/dev/null 2>&1
CHURNED=$(( AT_BACKUP + 4 ))
wait_count "$CHURNED" && ok "churned after the backup: ${AT_BACKUP} -> ${CHURNED} documents" || bad "churn did not land (count $(doc_count))"
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
restore_flag && ok "restoreCommand ran and exited 0" || bad "restoreCommand failed"
start_app "$NAME" >/dev/null 2>&1
if wait_health 90 && wait_count "$AT_BACKUP"; then
  ok "restore rolled the search data back: ${CHURNED} -> ${AT_BACKUP} documents"
else
  bad "restore did NOT roll back: ${AT_BACKUP} at backup, ${CHURNED} before restore, $(doc_count) after"
fi
in_data 'ls -d /app/db/quarantine-* >/dev/null 2>&1' && ok "the replaced store was kept in quarantine" || bad "no quarantine directory"
in_data 'test ! -e /app/db/.restore-pending' && ok "restore flag consumed" || bad "restore flag left behind"

# 8d. A restore of a backup that carries NO artefact must keep the live store, not replace it with
#     nothing, and must say so.
curl -s -m 10 -X POST "$B/indexes/smoke/documents" -H "Authorization: Bearer ${KEY}" \
  -H 'content-type: application/json' -d '[{"id":9,"t":"kept"}]' >/dev/null 2>&1
KEEP=$(( AT_BACKUP + 1 )); wait_count "$KEEP"
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
in_data 'rm -f /app/data/snapshots/* /app/data/dumps/*'
restore_flag
start_app "$NAME" >/dev/null 2>&1
if wait_health 90 && wait_count "$KEEP"; then ok "a restore with no artefact kept the live store (${KEEP} documents)"
else bad "a restore with no artefact lost data: $(doc_count) documents, expected ${KEEP}"; fi
"$ENGINE" logs "$NAME" 2>&1 | grep -ac 'NOT rolled back' >/dev/null && ok "and warned that nothing was rolled back" || bad "no warning for the unrollable restore"

# 8e. A failed backup is VISIBLE: with the app stopped the backup command cannot snapshot, still
#     exits 0 (one app's failure must not abort the server's backup, #312), writes the notice, and
#     the next boot prints it. A later good backup clears it.
"$ENGINE" stop -t 20 "$NAME" >/dev/null 2>&1
"$ENGINE" run --rm --read-only --tmpfs /run --tmpfs /tmp -v "$VOL":/app/data -v "$DBVOL":/app/db \
  --entrypoint /app/code/backup-snapshot.sh "$IMAGE" >/dev/null 2>&1 \
  && ok "a failing backup still exits 0" || bad "a failing backup exited non-zero (would abort the whole server backup)"
in_data 'test -s /app/data/BACKUP-FAILED.txt' && ok "a failing backup wrote BACKUP-FAILED.txt" || bad "no failure notice after a failed backup"
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
start_app "$NAME" >/dev/null 2>&1
wait_health 90
"$ENGINE" logs "$NAME" 2>&1 | grep -ac 'last backup did not complete' >/dev/null && ok "the next boot announced the failed backup" || bad "boot did not announce the failed backup"
backup_now
in_data 'test ! -e /app/data/BACKUP-FAILED.txt' && ok "a later good backup cleared the notice" || bad "notice survived a good backup"

# 9. And the refusal: with the store present but the key file gone, start.sh must REFUSE to boot
#    rather than generate a fresh key. Booting here is the data-loss path this test exists for.
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
"$ENGINE" run --rm -v "$VOL":/app/data -v "$DBVOL":/app/db --entrypoint sh "$IMAGE" -c 'rm -f /app/data/master-key' >/dev/null 2>&1
start_app "$NAME" >/dev/null 2>&1
sleep 12
if wait_health 5; then
  bad "booted with the key file missing over an existing store — it minted a new master key"
else
  "$ENGINE" logs "$NAME" 2>&1 | grep -aqiE 'master.key|refus|missing' \
    && ok "refuses to boot when the key file is gone but the store exists" \
    || bad "did not start, but the logs do not explain why (expected an explicit master-key refusal)"
fi

echo
echo "=== smoke result: ${fails} failure(s) ==="
[ "$fails" = 0 ] || "$ENGINE" logs "$NAME" 2>&1 | tail -40
exit $((fails > 0 ? 1 : 0))
