#!/bin/bash
# -------- #
# VARIABLE #
# -------- #
# ----- script ----- #
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
# ----- .env (existence check before sourcing) ----- #
if [ ! -r "${SCRIPT_PATH}/.env" ]; then
  echo "ERROR: .env not found or not readable at ${SCRIPT_PATH}/.env" >&2
  exit 1
fi
source "${SCRIPT_PATH}/.env"
# ----- logging ----- #
LOG_FILE="${SCRIPT_PATH}/conoha_dns.log"
# .env で未設定なら既定値を使う（後方互換）
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"   # ローテート閾値 (default 1 MiB)
LOG_GENERATIONS="${LOG_GENERATIONS:-3}"      # 保持世代数 (.1 .. .N)
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [${SCRIPT_NAME}] $*" | tee -a "${LOG_FILE}" >&2
}
# 閾値超過時のみ世代ローテート。総容量は LOG_MAX_BYTES x (LOG_GENERATIONS+1) で頭打ち
rotate_log() {
  [ -f "${LOG_FILE}" ] || return 0
  local size g
  size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
  [ "${size}" -lt "${LOG_MAX_BYTES}" ] && return 0
  for ((g=LOG_GENERATIONS-1; g>=1; g--)); do
    [ -f "${LOG_FILE}.${g}" ] && mv -f "${LOG_FILE}.${g}" "${LOG_FILE}.$((g+1))"
  done
  mv -f "${LOG_FILE}" "${LOG_FILE}.1"
  rm -f "${LOG_FILE}.$((LOG_GENERATIONS+1))"
}
rotate_log
# ----- conoha_dns_api.sh  ----- #
CNH_DNS_DOMAIN=${CERTBOT_DOMAIN}'.'
CNH_DNS_NAME='_acme-challenge.'${CNH_DNS_DOMAIN}
CNH_DNS_TYPE="TXT"
CNH_DNS_DATA=${CERTBOT_VALIDATION}

log "=== auth hook start: ${CNH_DNS_NAME} ==="

# -------- #
# API LOAD #
# -------- #
if [ "${CNH_REGION}" = "tyo1" ] || [ "${CNH_REGION}" = "tyo2" ]; then
  source "${SCRIPT_PATH}/conoha_dns_api_v2.sh"
else
  source "${SCRIPT_PATH}/conoha_dns_api_v3.sh"
fi

# --------------------- #
# VALIDATE AUTH / DOMAIN #
# --------------------- #
if [ -z "${CNH_TOKEN}" ]; then
  log "ERROR: Failed to obtain API token. Check credentials in .env"
  exit 1
fi
if [ -z "${CNH_DOMAIN_ID}" ]; then
  log "ERROR: Domain ID not found for ${CNH_DNS_DOMAIN}. Is the zone registered in ConoHa DNS?"
  exit 1
fi
log "auth OK (domain_id=${CNH_DOMAIN_ID})"

# ----------------- #
# CREATE DNS RECORD #
# ----------------- #
CREATE_RESULT=$(create_conoha_dns_record)
CREATE_RC=$?
log "create response: ${CREATE_RESULT}"
if [ ${CREATE_RC} -ne 0 ]; then
  log "ERROR: Failed to create TXT record (non-2xx HTTP status)"
  exit 1
fi

# ---------------------------------------------- #
# RESOLVE AUTHORITATIVE NAMESERVERS (apex)        #
# ---------------------------------------------- #
# CNH_DNS_DOMAIN は ${CERTBOT_DOMAIN}. なので、そのまま NS を引く。
# サブドメインで直接 NS が引けない場合は親へ遡る。
NS_TARGET="${CNH_DNS_DOMAIN}"
mapfile -t AUTH_NS < <(dig +short NS "${NS_TARGET}")
while [ ${#AUTH_NS[@]} -eq 0 ] && [ -n "${NS_TARGET}" ] && [ "${NS_TARGET}" != "." ]; do
  NS_TARGET=$(echo "${NS_TARGET}" | sed 's/^[^.]*\.//')
  [ -z "${NS_TARGET}" ] && break
  mapfile -t AUTH_NS < <(dig +short NS "${NS_TARGET}")
done
if [ ${#AUTH_NS[@]} -eq 0 ]; then
  log "ERROR: Failed to resolve authoritative NS for ${CNH_DNS_DOMAIN}"
  exit 1
fi
log "authoritative NS: ${AUTH_NS[*]}"

# ---------------------------------------------- #
# POLL UNTIL TXT IS VISIBLE ON *ALL* NS           #
# ---------------------------------------------- #
RETRY_INTERVAL=5
MAX_RETRIES=36   # 5s x 36 = up to 3 min
ns_unreachable=0
for ((i=1; i<=MAX_RETRIES; i++)); do
  all_ok=1
  pending_ns=""
  ns_unreachable=0
  for ns in "${AUTH_NS[@]}"; do
    dig_out=$(dig +short TXT "${CNH_DNS_NAME}" @"${ns}" 2>/dev/null)
    dig_rc=$?
    if [ ${dig_rc} -ne 0 ]; then
      # NS が到達不可/名前解決不可。レコード未反映とは別問題。
      all_ok=0
      pending_ns="${ns}"
      ns_unreachable=1
      break
    fi
    if ! printf '%s' "${dig_out}" | tr -d '"' | grep -qF "${CNH_DNS_DATA}"; then
      all_ok=0
      pending_ns="${ns}"
      break
    fi
  done
  if [ ${all_ok} -eq 1 ]; then
    log "TXT record visible on all NS (attempt ${i}/${MAX_RETRIES})"
    sleep 5   # safety margin for NS-to-NS replication
    log "=== auth hook done ==="
    exit 0
  fi
  if [ ${ns_unreachable} -eq 1 ]; then
    log "attempt ${i}/${MAX_RETRIES}: NS query to ${pending_ns} failed (unreachable). retry in ${RETRY_INTERVAL}s"
  else
    log "attempt ${i}/${MAX_RETRIES}: not visible yet on ${pending_ns}. retry in ${RETRY_INTERVAL}s"
  fi
  sleep ${RETRY_INTERVAL}
done

if [ ${ns_unreachable} -eq 1 ]; then
  log "ERROR: Could not query authoritative NS ${pending_ns} (unreachable/unresolvable). The TXT record may actually exist; check connectivity to the NS."
else
  log "ERROR: TXT record did not propagate to all NS within timeout"
fi
exit 1
