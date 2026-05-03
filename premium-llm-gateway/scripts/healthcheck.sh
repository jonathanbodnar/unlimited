#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh
#
# End-to-end check that the gateway is reachable and able to serve a real
# completion. Exits non-zero on any failure so it's safe to run from cron.
#
# Usage:
#   ./scripts/healthcheck.sh                    # uses .env
#   LITELLM_BASE_URL=https://api.example.com/ ./scripts/healthcheck.sh
#
# Requires:
#   curl, jq (optional — graceful fallback if absent)
#   LITELLM_MASTER_KEY in env or .env (used for /v1/models)
#   TEST_KEY in env or .env (used for /chat/completions). Falls back to master.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

BASE_URL="${LITELLM_BASE_URL:-http://localhost:4000}"
ADMIN_KEY="${LITELLM_MASTER_KEY:-}"
USER_KEY="${TEST_KEY:-${ADMIN_KEY}}"
MODEL="${TEST_MODEL:-dev-auto}"

ok()   { printf '\033[32m  OK\033[0m  %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

[[ -n "${ADMIN_KEY}" && "${ADMIN_KEY}" != "sk-admin-replace-me" ]] \
  || fail "LITELLM_MASTER_KEY is unset or still the placeholder"

echo "Target: ${BASE_URL}"
echo "Model:  ${MODEL}"
echo

# 1) liveliness — proxy process up
status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL%/}/health/liveliness" || echo "000")
[[ "${status}" == "200" ]] && ok "liveliness 200" || fail "liveliness returned ${status}"

# 2) readiness — DB + callbacks ready
status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL%/}/health/readiness" || echo "000")
[[ "${status}" == "200" ]] && ok "readiness 200" || fail "readiness returned ${status}"

# 3) /v1/models — admin auth works
models_resp=$(curl -sS "${BASE_URL%/}/v1/models" \
  -H "Authorization: Bearer ${ADMIN_KEY}")
if command -v jq >/dev/null 2>&1; then
  count=$(echo "${models_resp}" | jq -r '.data | length' 2>/dev/null || echo "0")
else
  count=$(echo "${models_resp}" | grep -oE '"id"[[:space:]]*:' | wc -l | tr -d ' ')
fi
[[ "${count}" -ge 1 ]] && ok "/v1/models returned ${count} models" \
  || fail "/v1/models returned no models — response: ${models_resp}"

# 4) tiny completion through dev-auto using the user key
prompt='{"model":"'"${MODEL}"'","messages":[{"role":"user","content":"reply with the single word: pong"}],"max_tokens":8}'
chat_resp=$(curl -sS -X POST "${BASE_URL%/}/v1/chat/completions" \
  -H "Authorization: Bearer ${USER_KEY}" \
  -H "Content-Type: application/json" \
  -d "${prompt}")
if command -v jq >/dev/null 2>&1; then
  content=$(echo "${chat_resp}" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
  used_model=$(echo "${chat_resp}" | jq -r '.model // empty' 2>/dev/null || true)
else
  content=$(echo "${chat_resp}" | grep -oE '"content"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || true)
  used_model=$(echo "${chat_resp}" | grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || true)
fi

if [[ -n "${content}" ]]; then
  ok "chat completion succeeded (model_used=${used_model:-unknown})"
  echo "      response: ${content}"
else
  fail "chat completion failed — response: ${chat_resp}"
fi

echo
echo "All checks passed."
