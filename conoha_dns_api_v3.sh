#!/bin/bash
# -------- #
# FUNCTION #
# -------- #
get_conoha_token(){
  curl -si https://identity.${CNH_REGION}.conoha.io/v3/auth/tokens \
  -X POST \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"auth": {"identity": {"methods": ["password"],"password": {"user": {"name": "'${CNH_USERNAME}'","password": "'${CNH_PASSWORD}'"}}},"scope": {"project": {"id": "'${CNH_TENANT_ID}'"}}}}' \
  | grep -i x-subject-token | awk -F': ' '{print $2}' | tr -d '\r\n'
}
get_conoha_domain_id(){
  curl -sS https://dns-service.${CNH_REGION}.conoha.io/v1/domains \
  -X GET \
  -H "Accept: application/json" \
  -H "X-Auth-Token: ${CNH_TOKEN}" \
  | jq -r --arg target "${CNH_DNS_DOMAIN}" '
      [.domains[] | select($target == .name or ($target | endswith("." + .name)))]
      | max_by(.name | length)
      | .uuid // empty
    '
}
# 戻り値: stdout にレスポンスボディ / 終了コード 0=成功(2xx) 1=失敗
create_conoha_dns_record(){
  local response http_code body
  response=$(curl -sS -w '\n%{http_code}' https://dns-service.${CNH_REGION}.conoha.io/v1/domains/${CNH_DOMAIN_ID}/records \
    -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Auth-Token: ${CNH_TOKEN}" \
    -d '{ "name": "'${CNH_DNS_NAME}'", "type": "'${CNH_DNS_TYPE}'", "data": "'${CNH_DNS_DATA}'", "ttl": 60 }')
  http_code=$(printf '%s' "$response" | tail -n1)
  body=$(printf '%s' "$response" | sed '$d')
  printf '%s\n' "$body"
  case "$http_code" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}
# 戻り値: stdout に一致レコードの uuid (0..n行)
get_conoha_dns_record_id(){
  curl -sS https://dns-service.${CNH_REGION}.conoha.io/v1/domains/${CNH_DOMAIN_ID}/records \
  -X GET \
  -H "Accept: application/json" \
  -H "X-Auth-Token: ${CNH_TOKEN}" \
  | jq -r '.records[] | select(.name == "'${CNH_DNS_NAME}'" and .data == "'${CNH_DNS_DATA}'") | .uuid'
}
# 戻り値: 終了コード 0=成功(2xx) 1=失敗
delete_conoha_dns_record(){
  local delete_id=$1
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' https://dns-service.${CNH_REGION}.conoha.io/v1/domains/${CNH_DOMAIN_ID}/records/${delete_id} \
    -X DELETE \
    -H "Accept: application/json" \
    -H "X-Auth-Token: ${CNH_TOKEN}")
  case "$http_code" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}
# ----------- #
# GET A TOKEN #
# ----------- #
CNH_TOKEN=$(get_conoha_token)
# ----------------- #
# GET THE DOMAIN ID #
# ----------------- #
CNH_DOMAIN_ID=$(get_conoha_domain_id)
