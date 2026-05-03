#!/usr/bin/env bash
# =============================================================================
# generate_key.sh
#
# Create a LiteLLM virtual API key for a test user.
# Defaults match the spec's Jonathan / premium_user_full_weight test key.
#
# Usage:
#   ./scripts/generate_key.sh                            # defaults
#   ./scripts/generate_key.sh -u alice -t balanced       # custom user/test
#   ./scripts/generate_key.sh -u jonathan -b 500 -d 14d  # 14-day, $500 cap
#
# Env (auto-loaded from ../.env if present):
#   LITELLM_BASE_URL    default: http://localhost:4000
#   LITELLM_MASTER_KEY  required (admin key)
#
# Notes:
#   - Never put the master key into Cursor or any client.
#   - Returned key starts with `sk-` and should be stored in a password manager.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env for LITELLM_MASTER_KEY if it exists.
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

USER_ID="jonathan"
TEST_TYPE="premium_user_full_weight"
DURATION="30d"
MAX_BUDGET="2000"
MODELS='["dev-auto", "mimo-pro", "deepseek-v4-pro", "deepseek-v4-flash", "claude-benchmark"]'
BASE_URL="${LITELLM_BASE_URL:-http://localhost:4000}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-u user_id] [-t test_type] [-d duration] [-b max_budget] [-m models_json] [-U base_url]

  -u user_id      tag stored in key metadata (default: ${USER_ID})
  -t test_type    e.g. premium_user_full_weight | balanced | aggressive_margin
  -d duration     LiteLLM duration string, e.g. 30d / 14d / 24h (default: ${DURATION})
  -b max_budget   USD budget cap (default: ${MAX_BUDGET})
  -m models_json  JSON array of allowed model names (default: all)
  -U base_url     LiteLLM admin URL (default: ${BASE_URL})
  -h              show this help

Requires LITELLM_MASTER_KEY in env or .env.
EOF
}

while getopts "u:t:d:b:m:U:h" opt; do
  case "${opt}" in
    u) USER_ID="${OPTARG}" ;;
    t) TEST_TYPE="${OPTARG}" ;;
    d) DURATION="${OPTARG}" ;;
    b) MAX_BUDGET="${OPTARG}" ;;
    m) MODELS="${OPTARG}" ;;
    U) BASE_URL="${OPTARG}" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "${LITELLM_MASTER_KEY:-}" || "${LITELLM_MASTER_KEY}" == "sk-admin-replace-me" ]]; then
  echo "ERROR: LITELLM_MASTER_KEY is unset or still the placeholder." >&2
  echo "Set it in .env or export it before running this script." >&2
  exit 2
fi

PAYLOAD=$(cat <<JSON
{
  "models": ${MODELS},
  "duration": "${DURATION}",
  "max_budget": ${MAX_BUDGET},
  "metadata": {
    "user_id": "${USER_ID}",
    "test_type": "${TEST_TYPE}"
  }
}
JSON
)

echo "Creating virtual key:"
echo "  base_url:  ${BASE_URL}"
echo "  user_id:   ${USER_ID}"
echo "  test_type: ${TEST_TYPE}"
echo "  duration:  ${DURATION}"
echo "  budget:    \$${MAX_BUDGET}"
echo

RESPONSE=$(curl -sS -X POST "${BASE_URL%/}/key/generate" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

echo "${RESPONSE}"
echo

# Try to extract the key with python (works on any macOS/Linux box) and remind
# the operator to store it. Fall back to grep if python isn't available.
if command -v python3 >/dev/null 2>&1; then
  KEY=$(python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('key',''))" <<<"${RESPONSE}" || true)
elif command -v python >/dev/null 2>&1; then
  KEY=$(python -c "import json,sys;print(json.loads(sys.stdin.read()).get('key',''))" <<<"${RESPONSE}" || true)
else
  KEY=$(grep -oE '"key"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${RESPONSE}" | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
fi

if [[ -n "${KEY}" ]]; then
  echo "==============================================================="
  echo " Virtual key generated:"
  echo "   ${KEY}"
  echo
  echo " Store this immediately. It will not be shown again."
  echo " Use it in Cursor (model: dev-auto)."
  echo "==============================================================="
fi
