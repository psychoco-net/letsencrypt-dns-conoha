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

log "=== cleanup hook start: ${CNH_DNS_NAME} ==="

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
# cleanup失敗で証明書発行全体を止めないよう、ここでは exit 0 で抜ける
if [ -z "${CNH_TOKEN}" ]; then
  log "WARNING: Failed to obtain API token. Skipping cleanup."
  exit 0
fi
if [ -z "${CNH_DOMAIN_ID}" ]; then
  log "WARNING: Domain ID not found. Skipping cleanup."
  exit 0
fi

# ------------- #
# GET RECORD ID #
# ------------- #
# 同名同値のレコードが複数残っている場合も全て削除する
mapfile -t RECORD_IDS < <(get_conoha_dns_record_id)
if [ ${#RECORD_IDS[@]} -eq 0 ] || [ -z "${RECORD_IDS[0]}" ]; then
  log "No matching TXT record found (already removed?). Nothing to delete."
  log "=== cleanup hook done ==="
  exit 0
fi

# ----------------- #
# DELETE DNS RECORD #
# ----------------- #
for rid in "${RECORD_IDS[@]}"; do
  [ -z "${rid}" ] && continue
  if delete_conoha_dns_record "${rid}"; then
    log "deleted record ${rid}"
  else
    log "WARNING: failed to delete record ${rid} (non-2xx HTTP status)"
  fi
done
log "=== cleanup hook done ==="
exit 0
