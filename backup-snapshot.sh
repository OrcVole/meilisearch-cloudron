#!/bin/bash
#
# Cloudron backupCommand for Meilisearch.
#
# The platform runs this in a TEMPORARY container immediately before it walks /app/data, and the
# conditions there are not the conditions the app itself runs under:
#
#   * no CLOUDRON_* environment variables, so this script cannot learn the app's own address from
#     its environment; it reads /app/data/.endpoint, which the entrypoint writes on every boot;
#   * stdout and stderr are discarded, so the only durable record of what happened is the status
#     line this script appends to /app/data/.last-backup.log;
#   * the root filesystem is read-only, with /tmp and /run as tmpfs; /app/data and /app/db are
#     mounted, and /app/data is writable;
#   * it is attached to the cloudron network, so the app container is reachable by IP.
#
# It asks the running instance for a snapshot through its own API, because a snapshot is what
# Meilisearch itself considers a consistent, restorable artefact; a raw file copy of a live LMDB
# store is not. The snapshot lands in /app/data/snapshots, inside the tree the platform is about
# to back up, and the boot decision tree in start.sh imports it on a clone or a rollback restore.
#
# It exits 0 in every case, deliberately. A backup command that fails takes the platform's whole
# backup run down with it, which is a worse outcome than a backup whose snapshot is one cycle
# stale, and the status line records honestly which of the two happened.

set -uo pipefail

DATA=/app/data
SNAPDIR="${DATA}/snapshots"
ENDPOINT_FILE="${DATA}/.endpoint"
KEYFILE="${DATA}/master-key"
LOGFILE="${DATA}/.last-backup.log"
LOG_MAX_LINES=100
POLL_INTERVAL=5
POLL_TIMEOUT=600
RETAIN_SNAPSHOTS="${MEILISEARCH_RETAIN_SNAPSHOTS:-2}"

# Append one line to the status log, then trim it. Every step tolerates failure, because a
# read-only or full /app/data must not turn into a non-zero exit.
record() {
  local outcome="$1" detail="$2" line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${outcome} ${detail}"
  echo "${line}" >> "${LOGFILE}" 2>/dev/null || return 0
  local count
  count="$(wc -l < "${LOGFILE}" 2>/dev/null || echo 0)"
  if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > LOG_MAX_LINES )); then
    tail -n "${LOG_MAX_LINES}" "${LOGFILE}" > "${LOGFILE}.trim" 2>/dev/null \
      && mv "${LOGFILE}.trim" "${LOGFILE}" 2>/dev/null || true
  fi
  return 0
}

# Nothing below this point may exit non-zero. Every failure path calls record and exits 0.

if [[ ! -r "${ENDPOINT_FILE}" ]]; then
  record failed "no endpoint file at ${ENDPOINT_FILE}; the app has not booted since install"
  exit 0
fi
ENDPOINT="$(tr -d '[:space:]' < "${ENDPOINT_FILE}" 2>/dev/null || true)"
if [[ -z "${ENDPOINT}" ]]; then
  record failed "endpoint file is empty"
  exit 0
fi

if [[ ! -r "${KEYFILE}" ]]; then
  record failed "cannot read the master key at ${KEYFILE}"
  exit 0
fi
KEY="$(tr -d '[:space:]' < "${KEYFILE}" 2>/dev/null || true)"
if [[ -z "${KEY}" ]]; then
  record failed "master key file is empty"
  exit 0
fi

# Is the instance actually up? A dead app must cost one connection timeout, not ten minutes.
if ! curl -fsS -m 15 -o /dev/null "${ENDPOINT}/health" 2>/dev/null; then
  record skipped "no healthy response from ${ENDPOINT}/health; app stopped or unreachable"
  exit 0
fi

RESPONSE="$(curl -fsS -m 60 -X POST "${ENDPOINT}/snapshots" \
  -H "Authorization: Bearer ${KEY}" 2>/dev/null || true)"
TASK_UID="$(printf '%s' "${RESPONSE}" | jq -r '.taskUid // empty' 2>/dev/null || true)"
if [[ -z "${TASK_UID}" ]]; then
  record failed "POST ${ENDPOINT}/snapshots did not return a task uid"
  exit 0
fi

DEADLINE=$(( $(date +%s) + POLL_TIMEOUT ))
STATUS=unknown
while (( $(date +%s) < DEADLINE )); do
  STATUS="$(curl -fsS -m 15 -H "Authorization: Bearer ${KEY}" \
    "${ENDPOINT}/tasks/${TASK_UID}" 2>/dev/null \
    | jq -r '.status // "unreachable"' 2>/dev/null || echo unreachable)"
  case "${STATUS}" in
    succeeded|failed|canceled) break ;;
    *) sleep "${POLL_INTERVAL}" ;;
  esac
done

if [[ "${STATUS}" != succeeded ]]; then
  record failed "snapshot task ${TASK_UID} ended as ${STATUS} (timeout ${POLL_TIMEOUT}s)"
  exit 0
fi

# Prune to the newest few snapshots before the platform walks the tree, so the backup carries one
# usable artefact rather than every snapshot ever taken. Best effort, like everything else here.
if [[ -d "${SNAPDIR}" ]] && [[ "${RETAIN_SNAPSHOTS}" =~ ^[0-9]+$ ]]; then
  while IFS= read -r victim; do
    [[ -n "${victim}" ]] || continue
    rm -f "${victim}" 2>/dev/null || true
  done < <(find "${SNAPDIR}" -maxdepth 1 -type f -name '*.snapshot' -printf '%T@ %p\n' \
    2>/dev/null | sort -rn | tail -n +$(( RETAIN_SNAPSHOTS + 1 )) | cut -d' ' -f2- || true)
fi

record succeeded "snapshot task ${TASK_UID} completed"
exit 0
