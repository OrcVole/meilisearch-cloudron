#!/bin/bash
#
# Cloudron entrypoint for Meilisearch.
#
# Runs as root, prepares /app/data and /app/db, generates the master key on first run only,
# decides which of the restore legs in docs/decisions/0005-boot-decision-tree.md applies, then
# drops to the cloudron user and execs the search server. Every package-emitted line is prefixed
# with "==>" so the logs are greppable. See docs/DEBUGGING.md for the boot ladder.
#
# ---------------------------------------------------------------------------------------------
# Operator overrides: /app/data/env
# ---------------------------------------------------------------------------------------------
# If /app/data/env exists it is sourced as a shell fragment before anything is computed, so it
# can set any of the variables below. Write it as plain KEY=value lines, one per line. It is
# read by root, so treat it as privileged: anything in it runs with root's authority at boot.
#
# Supported, in the sense that the package computes a default and stands out of the way if the
# operator sets one:
#
#   MEILI_LOG_LEVEL                     OFF, ERROR, WARN, INFO (default), DEBUG, TRACE
#   MEILI_MAX_INDEXING_MEMORY           bytes; default is the cgroup limit divided by three
#   MEILI_MAX_INDEXING_THREADS          upstream default is half the available cores
#   MEILI_SCHEDULE_SNAPSHOT             seconds between built-in snapshots; default 86400
#   MEILI_HTTP_PAYLOAD_SIZE_LIMIT       bytes; upstream default is 100 MB
#   MEILI_TASK_WEBHOOK_URL              a URL Meilisearch posts finished tasks to
#   MEILI_EXPERIMENTAL_ENABLE_METRICS   true to expose the Prometheus route
#   MEILI_EXPERIMENTAL_CONTAINS_FILTER  true to enable the CONTAINS filter operator
#   MEILI_EXPERIMENTAL_*                any other experimental flag the pinned version accepts
#   MEILISEARCH_UPGRADE_TIMEOUT         seconds to allow a database upgrade; default 3600
#   MEILISEARCH_HEALTH_TIMEOUT          seconds to wait for health before giving up on the
#                                       version marker; default 300
#   MEILISEARCH_RETAIN_SNAPSHOTS        how many snapshot files to keep; default 2
#   MEILISEARCH_RETAIN_DUMPS            how many dump files to keep; default 2
#   MEILISEARCH_QUARANTINE_DAYS         age at which a quarantined store is deleted; default 30
#
# Forced by the package and overwritten after the file is sourced, so setting them has no
# effect: MEILI_ENV, MEILI_HTTP_ADDR, MEILI_DB_PATH, MEILI_SNAPSHOT_DIR, MEILI_DUMP_DIR,
# MEILI_NO_ANALYTICS, MEILI_MASTER_KEY, MEILI_IMPORT_SNAPSHOT, MEILI_IMPORT_DUMP,
# MEILI_UPGRADE_DB. The restore decision tree owns the import and upgrade variables, and the
# rest are structural: changing them would move the data out of the backed-up tree or turn off
# authentication.
#
# Flags removed upstream in 1.51.0 and therefore never passed here:
# --experimental-no-snapshot-compaction, --experimental-replication-parameters,
# --experimental-no-edition-2024-for-dumps, and the old experimental spelling of --upgrade-db.

set -euo pipefail

CODE=/app/code
DATA=/app/data
DB=/app/db
BIN="${CODE}/meilisearch"
STORE="${DB}/data.ms"
MARKER="${DB}/.meili-version"
KEYFILE="${DATA}/master-key"
SNAPDIR="${DATA}/snapshots"
DUMPDIR="${DATA}/dumps"
ENDPOINT_FILE="${DATA}/.endpoint"
ENV_FILE="${DATA}/env"
PORT=7700
LOCAL="http://127.0.0.1:${PORT}"
VERSION="${MEILISEARCH_VERSION:-unknown}"

log()  { echo "==> [start] $*"; }
warn() { echo "==> [start] WARNING: $*" >&2; }
fail() { echo "==> [start] FATAL: $*" >&2; exit 1; }

# While the supervised database upgrade runs (leg 3 below), this script is PID 1 and the server
# is its child. A process running as PID 1 receives no default signal dispositions, so without
# this trap a stop request would be ignored here and the platform would eventually SIGKILL the
# whole container in the middle of a migration, which is the corruption this package is trying
# hardest to avoid. Forward the signal instead and let the server shut down cleanly.
UPGRADE_PID=""
forward_term() {
  if [[ -n "${UPGRADE_PID}" ]] && kill -0 "${UPGRADE_PID}" 2>/dev/null; then
    warn "stop requested during the supervised upgrade; forwarding it to the server"
    kill -TERM "${UPGRADE_PID}" 2>/dev/null || true
    wait "${UPGRADE_PID}" 2>/dev/null || true
  fi
  exit 143
}
trap forward_term TERM INT

log "Meilisearch ${VERSION} booting"

# ---------------------------------------------------------------------------------------------
# 1. Layout and ownership. A backup or a restore can reset both, so they are re-asserted on
#    every boot rather than only on first run.
# ---------------------------------------------------------------------------------------------
mkdir -p "${DATA}" "${DB}" "${SNAPDIR}" "${DUMPDIR}"
chown -R cloudron:cloudron "${DATA}" "${DB}"
if [[ -f "${KEYFILE}" ]]; then
  chown cloudron:cloudron "${KEYFILE}"
  chmod 0600 "${KEYFILE}"
fi
log "prepared ${DATA} (master key, snapshots, dumps) and ${DB} (store)"

# ---------------------------------------------------------------------------------------------
# 2. Endpoint file. The backup command runs in a separate temporary container with no CLOUDRON_*
#    environment, so it cannot discover this container's address by itself. Writing the address
#    here on every boot is what lets it find the running instance. `hostname -I` can lead with an
#    IPv6 address, so filter for the first IPv4 rather than taking the first field.
# ---------------------------------------------------------------------------------------------
CONTAINER_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
  | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n 1 || true)"
if [[ -z "${CONTAINER_IP}" ]]; then
  warn "no IPv4 address found; writing a loopback endpoint, which the backup command cannot reach"
  CONTAINER_IP=127.0.0.1
fi
printf 'http://%s:%s\n' "${CONTAINER_IP}" "${PORT}" > "${ENDPOINT_FILE}"
chown cloudron:cloudron "${ENDPOINT_FILE}"
chmod 0640 "${ENDPOINT_FILE}"
log "endpoint : http://${CONTAINER_IP}:${PORT} (written to ${ENDPOINT_FILE})"

# ---------------------------------------------------------------------------------------------
# 3. Operator overrides, sourced before anything is computed so that a value set here survives.
# ---------------------------------------------------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
  log "sourcing operator overrides from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090,SC1091
  . "${ENV_FILE}"
  set +a
fi

UPGRADE_TIMEOUT="${MEILISEARCH_UPGRADE_TIMEOUT:-3600}"
HEALTH_TIMEOUT="${MEILISEARCH_HEALTH_TIMEOUT:-300}"
RETAIN_SNAPSHOTS="${MEILISEARCH_RETAIN_SNAPSHOTS:-2}"
RETAIN_DUMPS="${MEILISEARCH_RETAIN_DUMPS:-2}"
QUARANTINE_DAYS="${MEILISEARCH_QUARANTINE_DAYS:-30}"

# ---------------------------------------------------------------------------------------------
# 4. Indexing memory. Upstream issue 4686: Meilisearch sizes its indexing buffers from the RAM it
#    can see on the host, not from the container's cgroup limit, so on a memory-limited container
#    it will happily plan an operation larger than the container is allowed and be killed rather
#    than fail in a controlled way. Compute the value from the cgroup instead, at one third of
#    the limit, with a 256 MiB floor so a very small limit still starts.
# ---------------------------------------------------------------------------------------------
MEMORY_FLOOR=268435456
memory_limit=""
memory_source=""
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  memory_limit="$(cat /sys/fs/cgroup/memory.max)"
  memory_source="cgroup v2 memory.max"
elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
  memory_limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  memory_source="cgroup v1 memory.limit_in_bytes"
fi
# "max" on cgroup v2, and the enormous sentinel cgroup v1 uses, both mean "no limit set".
if [[ ! "${memory_limit}" =~ ^[0-9]+$ ]] || (( memory_limit > 1099511627776 )); then
  memory_limit="$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)"
  memory_source="host MemTotal (no cgroup limit visible)"
fi
computed_indexing_memory=$(( memory_limit / 3 ))
if (( computed_indexing_memory < MEMORY_FLOOR )); then
  computed_indexing_memory="${MEMORY_FLOOR}"
fi
if [[ -n "${MEILI_MAX_INDEXING_MEMORY:-}" ]]; then
  log "memory   : limit $((memory_limit / 1048576)) MiB from ${memory_source}; indexing memory" \
      "$(( MEILI_MAX_INDEXING_MEMORY / 1048576 )) MiB (operator override)"
else
  export MEILI_MAX_INDEXING_MEMORY="${computed_indexing_memory}"
  log "memory   : limit $((memory_limit / 1048576)) MiB from ${memory_source}; indexing memory" \
      "$(( MEILI_MAX_INDEXING_MEMORY / 1048576 )) MiB (limit / 3, floor 256 MiB)"
fi

# ---------------------------------------------------------------------------------------------
# 5. The master key. Every API key Meilisearch issues is derived from it, so regenerating it
#    silently invalidates every key every consumer holds. Generate once, never again, and refuse
#    to generate a replacement next to a store that expects the old one (ADR 0003).
# ---------------------------------------------------------------------------------------------
if [[ -f "${KEYFILE}" ]]; then
  log "master key: existing key found at ${KEYFILE}"
elif [[ -e "${STORE}" ]]; then
  fail "${STORE} exists but ${KEYFILE} is missing. Generating a new master key here would" \
       "invalidate every API key derived from the old one, including keys held by other" \
       "applications. Restore ${KEYFILE} from a backup, or delete ${STORE} deliberately if the" \
       "data is genuinely expendable, then restart the app."
else
  log "master key: first run, generating"
  ( umask 077; openssl rand -hex 32 > "${KEYFILE}" )
  chown cloudron:cloudron "${KEYFILE}"
  chmod 0600 "${KEYFILE}"
  log "master key: written to ${KEYFILE} (mode 0600). Read it with: cat ${KEYFILE}"
fi
MEILI_MASTER_KEY="$(cat "${KEYFILE}")"
export MEILI_MASTER_KEY

# ---------------------------------------------------------------------------------------------
# 6. Forced settings. These are applied after the operator override file is sourced, so they win.
# ---------------------------------------------------------------------------------------------
export MEILI_ENV=production
export MEILI_NO_ANALYTICS=true
export MEILI_HTTP_ADDR="0.0.0.0:${PORT}"
export MEILI_DB_PATH="${STORE}"
export MEILI_SNAPSHOT_DIR="${SNAPDIR}"
export MEILI_DUMP_DIR="${DUMPDIR}"
export MEILI_SCHEDULE_SNAPSHOT="${MEILI_SCHEDULE_SNAPSHOT:-86400}"
unset MEILI_IMPORT_SNAPSHOT MEILI_IMPORT_DUMP MEILI_UPGRADE_DB

# ---------------------------------------------------------------------------------------------
# Helpers used by the decision tree below.
# ---------------------------------------------------------------------------------------------

# Newest file matching a glob in a directory, by modification time, or the empty string.
newest_file() {
  local dir="$1" pattern="$2"
  [[ -d "${dir}" ]] || return 0
  find "${dir}" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n 1 | cut -d' ' -f2-
}

# Compare two dotted versions. Echoes "older", "same" or "newer" for the first against the second.
version_compare() {
  local a="$1" b="$2"
  if [[ "${a}" == "${b}" ]]; then echo same; return 0; fi
  if [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n 1)" == "${a}" ]]; then
    echo older
  else
    echo newer
  fi
}

# Move the store aside into a dated directory and forget the marker, so the next boot treats the
# situation as a fresh store. Only ever called when there is an artefact to import in its place.
quarantine_store() {
  local reason="$1"
  local dir="${DB}/quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${dir}"
  mv "${STORE}" "${dir}/data.ms"
  rm -f "${MARKER}"
  chown -R cloudron:cloudron "${dir}"
  warn "moved the store aside to ${dir} (${reason}). It is not deleted; remove it by hand once" \
       "the import is confirmed good, or leave it and the package will delete it after" \
       "${QUARANTINE_DAYS} days."
}

# Run the database upgrade to completion in a supervised process, before the final exec.
#
# Deviation from the literal wording of ADR 0005, recorded in its History section: this process
# binds the real port rather than staying off the network. Meilisearch enqueues the upgrade as an
# ordinary task and serves /health while the task runs, so binding normally keeps the platform
# health check satisfied for the whole migration. Staying off the network would fail the health
# check and invite the platform to restart the container mid-migration, which is the exact
# corruption this leg exists to avoid (upstream issue 5280).
run_upgrade_phase() {
  local deadline status pid elapsed
  log "upgrade  : starting a supervised upgrade process (timeout ${UPGRADE_TIMEOUT}s)"
  MEILI_UPGRADE_DB=true gosu cloudron:cloudron "${BIN}" &
  pid=$!
  UPGRADE_PID="${pid}"

  deadline=$(( $(date +%s) + UPGRADE_TIMEOUT ))
  local healthy=no
  while (( $(date +%s) < deadline )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      warn "upgrade process exited before answering the health route"
      wait "${pid}" || true
      return 1
    fi
    if curl -fsS -m 5 -o /dev/null "${LOCAL}/health" 2>/dev/null; then healthy=yes; break; fi
    sleep 2
  done
  if [[ "${healthy}" != yes ]]; then
    warn "upgrade process never answered ${LOCAL}/health within ${UPGRADE_TIMEOUT}s"
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" || true
    return 1
  fi

  # The upgrade is an ordinary task, so poll for it. A database already at this version enqueues
  # no such task at all, which is a legitimate no-op: allow a short grace period before deciding
  # that is what happened.
  local none_since=""
  while (( $(date +%s) < deadline )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      warn "upgrade process exited while the upgrade task was still pending"
      wait "${pid}" || true
      return 1
    fi
    status="$(curl -fsS -m 10 -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
      "${LOCAL}/tasks?types=upgradeDatabase&limit=1" 2>/dev/null \
      | jq -r '.results[0].status // "none"' 2>/dev/null || echo unreachable)"
    case "${status}" in
      succeeded)
        log "upgrade  : upgradeDatabase task succeeded"
        break
        ;;
      failed|canceled)
        warn "upgradeDatabase task reported ${status}"
        kill -TERM "${pid}" 2>/dev/null || true
        wait "${pid}" || true
        return 1
        ;;
      none)
        [[ -n "${none_since}" ]] || none_since="$(date +%s)"
        elapsed=$(( $(date +%s) - none_since ))
        if (( elapsed >= 20 )); then
          log "upgrade  : no upgradeDatabase task was enqueued; the store was already current"
          break
        fi
        ;;
      *)
        : # enqueued, processing, or momentarily unreachable; keep waiting
        ;;
    esac
    sleep 5
  done

  log "upgrade  : stopping the supervised process before the final start"
  kill -TERM "${pid}" 2>/dev/null || true
  local stop_deadline=$(( $(date +%s) + 120 ))
  while kill -0 "${pid}" 2>/dev/null && (( $(date +%s) < stop_deadline )); do sleep 1; done
  if kill -0 "${pid}" 2>/dev/null; then
    warn "supervised upgrade process did not stop within 120s; sending KILL"
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  wait "${pid}" || true
  UPGRADE_PID=""
  return 0
}

# Build the import arguments for a store that has to be rebuilt from an artefact. Prefers the
# newest snapshot, falls back to the newest dump. Returns 1 when neither exists.
choose_import() {
  local snapshot dump
  snapshot="$(newest_file "${SNAPDIR}" '*.snapshot')"
  dump="$(newest_file "${DUMPDIR}" '*.dump')"
  if [[ -n "${snapshot}" ]]; then
    ARGS=(--import-snapshot "${snapshot}" --ignore-missing-snapshot)
    log "import   : newest snapshot ${snapshot}"
    return 0
  fi
  if [[ -n "${dump}" ]]; then
    ARGS=(--import-dump "${dump}" --ignore-missing-dump)
    log "import   : no snapshot found, newest dump ${dump}"
    return 0
  fi
  return 1
}

# Same, but dump first: the documented fallback when an in-place upgrade has failed, because the
# snapshot in the backup was written by the same version whose upgrade just failed.
choose_import_dump_first() {
  local snapshot dump
  dump="$(newest_file "${DUMPDIR}" '*.dump')"
  snapshot="$(newest_file "${SNAPDIR}" '*.snapshot')"
  if [[ -n "${dump}" ]]; then
    ARGS=(--import-dump "${dump}" --ignore-missing-dump)
    log "import   : newest dump ${dump}"
    return 0
  fi
  if [[ -n "${snapshot}" ]]; then
    ARGS=(--import-snapshot "${snapshot}" --ignore-missing-snapshot)
    log "import   : no dump found, newest snapshot ${snapshot}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------------------------
# 7. The boot decision tree (ADR 0005). Exactly one of these legs runs.
# ---------------------------------------------------------------------------------------------
ARGS=()
MARKER_VERSION=""
[[ -f "${MARKER}" ]] && MARKER_VERSION="$(tr -d '[:space:]' < "${MARKER}")"

if [[ ! -e "${STORE}" ]]; then
  # Leg 1: no store. A genuinely fresh install, or a clone, whose persistent directory starts
  # empty while /app/data arrives from the backup complete with snapshots and dumps.
  if choose_import; then
    log "leg      : 1, no store present, rebuilding from the newest artefact"
  else
    ARGS=()
    log "leg      : 1, no store and no artefact to import, starting empty (fresh install)"
  fi

elif [[ -z "${MARKER_VERSION}" ]]; then
  # A store with no marker. Either it predates the marker, or no previous boot ever became
  # healthy. Treat it as possibly older and let the supervised upgrade decide: the upgrade is a
  # no-op against a store that is already current.
  log "leg      : 3, store present with no version marker, treating as possibly older"
  if run_upgrade_phase; then
    log "upgrade  : complete"
  elif choose_import_dump_first; then
    quarantine_store "the database upgrade failed"
  else
    fail "the database upgrade failed and there is no dump or snapshot to rebuild from." \
         "The store is untouched at ${STORE}. Restore a backup, or inspect the store with" \
         "${CODE}/meilitool, before restarting."
  fi

else
  case "$(version_compare "${MARKER_VERSION}" "${VERSION}")" in
    same)
      log "leg      : 2, store written by ${MARKER_VERSION}, matching this binary, normal start"
      ;;
    older)
      log "leg      : 3, store written by ${MARKER_VERSION}, older than ${VERSION}, upgrading"
      if run_upgrade_phase; then
        log "upgrade  : complete"
      elif choose_import_dump_first; then
        quarantine_store "the database upgrade from ${MARKER_VERSION} failed"
      else
        fail "the upgrade from ${MARKER_VERSION} failed and there is no dump or snapshot to" \
             "rebuild from. The store is untouched at ${STORE}. Restore a backup, or inspect" \
             "the store with ${CODE}/meilitool, before restarting."
      fi
      ;;
    newer)
      # A rollback restore: the platform preserves the persistent directory, so the live store
      # can be newer than the /app/data that was restored around it. This binary refuses to open
      # such a store, so the store has to come from the restored artefacts instead.
      log "leg      : 4, store written by ${MARKER_VERSION}, newer than ${VERSION}, rolling back"
      if choose_import; then
        quarantine_store "the store was written by ${MARKER_VERSION}, newer than this binary"
      else
        fail "the store was written by ${MARKER_VERSION}, which is newer than this binary" \
             "(${VERSION}), and there is no snapshot or dump to rebuild from. The store is" \
             "untouched at ${STORE}. Reinstate the newer version, or restore a backup that" \
             "contains a snapshot, before restarting."
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------------------------
# 8. Pruning. Keep the newest few artefacts so the backed-up tree does not grow without bound,
#    and delete quarantined stores once they are old enough to be past any plausible rollback.
#    Nothing here is allowed to stop the boot, so every step tolerates failure.
# ---------------------------------------------------------------------------------------------
prune_oldest() {
  local dir="$1" pattern="$2" keep="$3" victim
  [[ -d "${dir}" ]] || return 0
  while IFS= read -r victim; do
    [[ -n "${victim}" ]] || continue
    log "prune    : removing ${victim}"
    rm -f "${victim}" || true
  done < <(find "${dir}" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +$(( keep + 1 )) | cut -d' ' -f2-)
}
prune_oldest "${SNAPDIR}" '*.snapshot' "${RETAIN_SNAPSHOTS}"
prune_oldest "${DUMPDIR}" '*.dump' "${RETAIN_DUMPS}"
while IFS= read -r victim; do
  [[ -n "${victim}" ]] || continue
  log "prune    : removing quarantined store ${victim} (older than ${QUARANTINE_DAYS} days)"
  rm -rf "${victim}" || true
done < <(find "${DB}" -maxdepth 1 -type d -name 'quarantine-*' \
  -mtime "+${QUARANTINE_DAYS}" 2>/dev/null || true)

# ---------------------------------------------------------------------------------------------
# 9. Version marker. Written only once the instance actually answers its health route, so a
#    marker never claims a version that failed to open the store. This subshell outlives the exec
#    below, because exec replaces this shell without touching its children.
# ---------------------------------------------------------------------------------------------
(
  marker_deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while (( $(date +%s) < marker_deadline )); do
    if curl -fsS -m 5 -o /dev/null "${LOCAL}/health" 2>/dev/null; then
      printf '%s\n' "${VERSION}" > "${MARKER}"
      chown cloudron:cloudron "${MARKER}" || true
      chmod 0644 "${MARKER}" || true
      echo "==> [start] marker   : healthy, ${MARKER} now records ${VERSION}"
      exit 0
    fi
    sleep 2
  done
  echo "==> [start] WARNING: no healthy response within ${HEALTH_TIMEOUT}s;" \
       "${MARKER} was left unchanged" >&2
) &

# ---------------------------------------------------------------------------------------------
# 10. Report the resolved facts (never the key itself) and hand off.
# ---------------------------------------------------------------------------------------------
chown -R cloudron:cloudron "${DATA}" "${DB}"
log "version  : ${VERSION} (marker was '${MARKER_VERSION:-none}')"
log "http     : ${MEILI_HTTP_ADDR} (production mode, every route except GET /health needs a key)"
log "store    : ${MEILI_DB_PATH}"
log "snapshots: ${MEILI_SNAPSHOT_DIR} (built-in schedule every ${MEILI_SCHEDULE_SNAPSHOT}s)"
log "dumps    : ${MEILI_DUMP_DIR}"
log "exec     : meilisearch ${ARGS[*]:-(no import arguments)}"

# tini, then gosu, then the server. The tini layer is not decoration: Meilisearch installs no
# SIGTERM handler, and a process running as PID 1 receives no default signal dispositions from
# the kernel, so as PID 1 it ignores SIGTERM outright and every stop, restart, update and backup
# ends in a SIGKILL after the platform's grace period (measured locally: 60s of ignored SIGTERM,
# against 187ms with tini). Upstream's own container image uses tini for the same reason. This is
# a deviation from the literal last line named in ADR 0002; see its History note.
exec /usr/bin/tini -- gosu cloudron:cloudron "${BIN}" "${ARGS[@]}"
