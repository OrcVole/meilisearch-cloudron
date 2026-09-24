#!/bin/bash
#
# Sign and inspect Meilisearch tenant tokens, and manage the API keys that sign them.
#
# Ported from james's Cloudron package (https://git.cloudron.io/playground/meilisearch-app,
# commit 45314aa), with his agreement on forum topic 15761. The commands, options and behaviour
# are his. What changed is the plumbing: the master key is read from /app/data/master-key, and the
# packaged signing key is switched on with MEILISEARCH_TENANT_TOKEN_KEY=true in /app/data/env
# (start.sh creates or deletes it once the server is healthy). See docs/TENANT-TOKENS.md.

set -eu -o pipefail

readonly MEILI_URL=http://127.0.0.1:7700
readonly TENANT_KEY_NAME="Cloudron tenant tokens"
readonly TENANT_KEY_FILE=/app/data/tenant-token-signing-key.env
export NO_COLOR=1

if [[ -z "${MEILI_MASTER_KEY:-}" ]]; then
    MEILI_MASTER_KEY=$(cat /app/data/master-key 2>/dev/null) \
        || { echo "$(basename "$0"): cannot read /app/data/master-key (run this in the app's Web Terminal)" >&2; exit 1; }
fi

meili_api() {
    local method=$1 path=$2 body=${3:-}
    curl -sS --fail-with-body -X "${method}" \
        -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
        -H 'Content-Type: application/json' \
        ${body:+--data "${body}"} \
        "${MEILI_URL}${path}"
}
PROG=$(basename "$0")
readonly PROG

usage() {
    cat <<EOF
Manage Meilisearch tenant tokens and the API keys that sign them.

Tenant tokens are not stored in Meilisearch. Each one is signed with a signing
key and carries its own search rules. Revoke tokens by letting them expire or
by deleting the key that signed them.

Usage: ${PROG} <command> [arguments]

Commands:
  create [options]                  Sign a new tenant token
  decode <token>                    Show the rules, signing key and expiry of a token
  search <token> <index> [query]    Search with a token to check what it can see
  keys                              List API keys that can sign tenant tokens
  key-create <name> [--index <index>]...
                                    Create a search-only signing key, all indexes by default
  key-delete <uid>                  Delete a signing key, revoking every token it signed

Options for create:
  --index <index>        Allow searching <index>. Repeat for several indexes. '*' means all
  --filter <filter>      Filter applied to the preceding --index, e.g. 'tenant_id = 42'
  --rules <json>         Raw search rules instead of --index/--filter
  --expires <when>       30m, 12h, 7d, 4w, a date like 2027-01-31, or 'never' (default: 24h)
  --key <uid>            Sign with this key instead of the packaged one
                         (MEILISEARCH_TENANT_TOKEN_KEY in /app/data/env)

Examples:
  ${PROG} create --index products --filter 'tenant_id = 42' --expires 7d
  ${PROG} create --index products --filter 'tenant_id = 42' --index articles --filter 'visibility = public'
  ${PROG} create --rules '{"docs": {}}' --expires never
  ${PROG} search "\$TOKEN" products shoes
  ${PROG} key-create "shop tenant tokens" --index products
EOF
}

die() {
    echo "${PROG}: $*" >&2
    exit 1
}

fail() {
    local message
    message=$(jq -r '.message // empty' <<< "$1" 2>/dev/null) || true
    die "${message:-cannot reach Meilisearch at ${MEILI_URL}}"
}

api() {
    local out
    out=$(meili_api "$@" 2>/dev/null) || fail "${out}"
    echo "${out}"
}

base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

base64url_decode() {
    local data
    data=$(tr -- '-_' '+/' <<< "$1")
    while (( ${#data} % 4 )); do data+='='; done
    openssl base64 -d -A <<< "${data}"
}

expires_at() {
    local when=$1
    declare -A seconds=([m]=60 [h]=3600 [d]=86400 [w]=604800)
    if [[ "${when}" == never ]]; then
        echo null
    elif [[ "${when}" =~ ^([0-9]+)([mhdw])$ ]]; then
        echo $(( $(date +%s) + BASH_REMATCH[1] * seconds[${BASH_REMATCH[2]}] ))
    else
        date -d "${when}" +%s 2>/dev/null || die "cannot parse --expires '${when}'"
    fi
}

cmd_create() {
    local rules='{}' raw_rules='' index='' expires=24h key_uid='' exp key header payload signature
    while (( $# )); do
        case "$1" in
            --index)
                index=${2:?--index needs a value}
                rules=$(jq -c --arg i "${index}" '.[$i] = {}' <<< "${rules}")
                shift 2 ;;
            --filter)
                [[ -n "${index}" ]] || die "--filter must follow an --index"
                rules=$(jq -c --arg i "${index}" --arg f "${2:?--filter needs a value}" '.[$i].filter = $f' <<< "${rules}")
                shift 2 ;;
            --rules) raw_rules=${2:?--rules needs a value}; shift 2 ;;
            --expires) expires=${2:?--expires needs a value}; shift 2 ;;
            --key) key_uid=${2:?--key needs a value}; shift 2 ;;
            *) die "unknown option '$1', see --help" ;;
        esac
    done

    if [[ -n "${raw_rules}" ]]; then
        [[ "${rules}" == '{}' ]] || die "use either --rules or --index/--filter"
        rules=$(jq -c . <<< "${raw_rules}" 2>/dev/null) || die "--rules is not valid JSON"
    fi
    [[ "${rules}" != '{}' ]] || die "a token needs at least one --index or --rules"

    if [[ -z "${key_uid}" ]]; then
        [[ -f "${TENANT_KEY_FILE}" ]] || die "no packaged signing key. Set MEILISEARCH_TENANT_TOKEN_KEY=true in /app/data/env and restart, or pass --key <uid>"
        key_uid=$(sed -n 's/^TENANT_TOKEN_API_KEY_UID=//p' "${TENANT_KEY_FILE}")
    fi
    key=$(api GET "/keys/${key_uid}" | jq -r .key)
    exp=$(expires_at "${expires}")

    header=$(printf '{"alg":"HS256","typ":"JWT"}' | base64url)
    payload=$(jq -njc --arg uid "${key_uid}" --argjson rules "${rules}" --argjson exp "${exp}" \
        '{apiKeyUid: $uid, searchRules: $rules} + (if $exp == null then {} else {exp: $exp} end)' | base64url)
    signature=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -hmac "${key}" -binary | base64url)

    echo "${header}.${payload}.${signature}"
}

cmd_decode() {
    local token=${1:?usage: ${PROG} decode <token>} payload exp
    [[ "${token}" == *.*.* ]] || die "not a JWT"
    payload=$(base64url_decode "$(cut -d. -f2 <<< "${token}")") || die "cannot decode token"
    jq . <<< "${payload}"
    exp=$(jq -r '.exp // empty' <<< "${payload}")
    if [[ -z "${exp}" ]]; then
        echo "Expires: never"
    elif (( exp < $(date +%s) )); then
        echo "Expired: $(date -d "@${exp}" -Iseconds)"
    else
        echo "Expires: $(date -d "@${exp}" -Iseconds)"
    fi
    if meili_api GET "/keys/$(jq -r .apiKeyUid <<< "${payload}")" >/dev/null 2>&1; then
        echo "Signing key: exists"
    else
        echo "Signing key: deleted, this token is revoked"
    fi
}

cmd_search() {
    local token=${1:?usage: ${PROG} search <token> <index> [query]} index=${2:?usage: ${PROG} search <token> <index> [query]} query=${3:-} out
    out=$(curl -s --fail-with-body -X POST \
        -H "Authorization: Bearer ${token}" \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg q "${query}" '{q: $q}')" \
        "${MEILI_URL}/indexes/${index}/search") || fail "${out}"
    jq '{estimatedTotalHits, hits}' <<< "${out}"
}

cmd_keys() {
    api GET '/keys?limit=1000' | jq -r --arg packaged "${TENANT_KEY_NAME}" '
        ["UID", "NAME", "INDEXES", "EXPIRES"],
        (.results[]
            | select(.actions | index("search") or index("*"))
            | [.uid, (.name // "-") + (if .name == $packaged then " (packaged)" else "" end), (.indexes | join(",")), (.expiresAt // "never")])
        | @tsv' | awk -F '\t' '{ printf "%-38s %-36s %-24s %s\n", $1, $2, $3, $4 }'
}

cmd_key_create() {
    local name=${1:?usage: ${PROG} key-create <name> [--index <index>]...} indexes='[]'
    shift
    while (( $# )); do
        case "$1" in
            --index) indexes=$(jq -c --arg i "${2:?--index needs a value}" '. + [$i]' <<< "${indexes}"); shift 2 ;;
            *) die "unknown option '$1', see --help" ;;
        esac
    done
    [[ "${indexes}" != '[]' ]] || indexes='["*"]'
    api POST /keys "$(jq -nc --arg name "${name}" --argjson indexes "${indexes}" \
        '{name: $name, description: "Tenant token signing key", actions: ["search"], indexes: $indexes, expiresAt: null}')" \
        | jq '{uid, name, indexes, key}'
    echo "Sign tokens with: ${PROG} create --key <uid> ..."
}

cmd_key_delete() {
    local uid=${1:?usage: ${PROG} key-delete <uid>} name
    name=$(api GET "/keys/${uid}" | jq -r .name)
    [[ "${name}" != "${TENANT_KEY_NAME}" ]] \
        || die "this is the packaged key, set MEILISEARCH_TENANT_TOKEN_KEY=false in /app/data/env and restart instead"
    api DELETE "/keys/${uid}" >/dev/null
    echo "Deleted ${uid}. Every token signed with it is now revoked."
}

case "${1:-}" in
    create) shift; cmd_create "$@" ;;
    decode) shift; cmd_decode "$@" ;;
    search) shift; cmd_search "$@" ;;
    keys) shift; cmd_keys ;;
    key-create) shift; cmd_key_create "$@" ;;
    key-delete) shift; cmd_key_delete "$@" ;;
    -h|--help|help|'') usage ;;
    *) die "unknown command '$1', see --help" ;;
esac
