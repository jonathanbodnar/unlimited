#!/usr/bin/env bash
# =============================================================================
# bootstrap_runpod.sh — one-shot setup of the LiteLLM stack on a RunPod pod.
#
# What it does (idempotent):
#   1. Verify docker + docker compose are present.
#   2. Clone or pull the repo into /workspace/unlimited.
#   3. Create premium-llm-gateway/.env if missing, taking values from the
#      environment (POSTGRES_PASSWORD, LITELLM_MASTER_KEY, MIMO_API_KEY, etc.).
#      Any missing value gets a sensible random default for passwords / secrets.
#   4. docker compose pull && docker compose up -d.
#   5. Wait for /health/readiness, then print the LiteLLM URL.
#
# Usage on the pod (after starting the pod from the RunPod UI):
#
#   curl -sSL https://raw.githubusercontent.com/jonathanbodnar/unlimited/main/premium-llm-gateway/scripts/bootstrap_runpod.sh \
#     | MIMO_API_KEY=... DEEPSEEK_API_KEY=... LITELLM_MASTER_KEY=... \
#       LANGFUSE_PUBLIC_KEY=... LANGFUSE_SECRET_KEY=... bash
#
# Or, if you already cloned the repo:
#   cd /workspace/unlimited/premium-llm-gateway
#   ./scripts/bootstrap_runpod.sh
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/jonathanbodnar/unlimited.git}"
REPO_DIR="${REPO_DIR:-/workspace/unlimited}"
GATEWAY_DIR="${REPO_DIR}/premium-llm-gateway"

log()  { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[bootstrap] ok\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[bootstrap] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1) docker + compose
log "checking docker"
command -v docker >/dev/null 2>&1 || fail "docker not found on this pod"
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
  || fail "docker daemon not reachable inside the pod"
if ! docker compose version >/dev/null 2>&1; then
  fail "docker compose v2 plugin not found; install it or pick a base image that ships with it"
fi
ok "docker $(docker version --format '{{.Server.Version}}') / compose $(docker compose version --short)"

# 2) clone or pull
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  log "cloning ${REPO_URL} into ${REPO_DIR}"
  mkdir -p "$(dirname "${REPO_DIR}")"
  git clone "${REPO_URL}" "${REPO_DIR}"
else
  log "pulling latest in ${REPO_DIR}"
  git -C "${REPO_DIR}" fetch --all --quiet
  git -C "${REPO_DIR}" pull --ff-only --quiet || log "pull skipped (local changes or detached HEAD)"
fi
[[ -d "${GATEWAY_DIR}" ]] || fail "gateway dir not found at ${GATEWAY_DIR}"
cd "${GATEWAY_DIR}"

# 3) build .env from environment
ENV_FILE="${GATEWAY_DIR}/.env"
randhex() { openssl rand -hex 24; }

if [[ -f "${ENV_FILE}" ]]; then
  ok ".env already exists at ${ENV_FILE} (will not overwrite)"
else
  log "creating ${ENV_FILE}"

  : "${POSTGRES_PASSWORD:=$(randhex)}"
  : "${LITELLM_MASTER_KEY:=sk-admin-$(randhex)}"
  : "${SESSION_SECRET:=$(openssl rand -hex 32)}"

  : "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY is required}"
  : "${MIMO_API_KEY:?MIMO_API_KEY is required}"

  : "${ANTHROPIC_API_KEY:=}"
  : "${OPENAI_API_KEY:=}"

  : "${LANGFUSE_PUBLIC_KEY:?LANGFUSE_PUBLIC_KEY is required}"
  : "${LANGFUSE_SECRET_KEY:?LANGFUSE_SECRET_KEY is required}"
  : "${LANGFUSE_HOST:=https://cloud.langfuse.com}"

  : "${ACTIVE_MODE:=A}"
  : "${PUBLIC_HOSTNAME:=}"

  cat > "${ENV_FILE}" <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}

DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
MIMO_API_KEY=${MIMO_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}

LANGFUSE_PUBLIC_KEY=${LANGFUSE_PUBLIC_KEY}
LANGFUSE_SECRET_KEY=${LANGFUSE_SECRET_KEY}
LANGFUSE_HOST=${LANGFUSE_HOST}

ACTIVE_MODE=${ACTIVE_MODE}
PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}
EOF
  chmod 600 "${ENV_FILE}"
  ok "wrote ${ENV_FILE}"
fi

# 4) start the stack
log "docker compose pull"
docker compose pull --quiet
log "docker compose up -d"
docker compose up -d
ok "stack is up"

# 5) wait for readiness
log "waiting for /health/readiness on http://localhost:4000 ..."
for i in $(seq 1 30); do
  status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/health/readiness || echo "000")
  if [[ "${status}" == "200" ]]; then
    ok "litellm is ready"
    break
  fi
  sleep 2
done

# Print the values the operator needs to plug into Railway.
LITELLM_MASTER_KEY_VAL=$(grep '^LITELLM_MASTER_KEY=' "${ENV_FILE}" | cut -d= -f2-)
POD_ID="${RUNPOD_POD_ID:-}"
if [[ -z "${POD_ID}" ]]; then
  POD_ID=$(hostname | sed -E 's/^[a-f0-9]+$//') || true
fi

cat <<SUMMARY

==============================================================================
RunPod LiteLLM stack is running.

Container status:
$(docker compose ps --format 'table {{.Service}}\t{{.Status}}')

Local health:
  curl http://localhost:4000/health/liveliness

To expose this to Railway:
  1. In the RunPod UI, edit the pod and add HTTP Service Port: 4000
  2. The pod will then be reachable at:
       https://<pod-id>-4000.proxy.runpod.net
     (Find <pod-id> in the RunPod UI; this pod's hostname is $(hostname).)

Plug these into the Railway service Variables:
  LITELLM_URL          = https://<pod-id>-4000.proxy.runpod.net
  LITELLM_MASTER_KEY   = ${LITELLM_MASTER_KEY_VAL}
  ADMIN_PASSWORD       = (pick a strong passphrase for the Railway UI)
  SESSION_SECRET       = \$(openssl rand -hex 32)

The Railway service will expose Cursor's base URL:
  https://<railway-domain>/v1

Generate a virtual key from the Railway UI, then put that key in Cursor.
==============================================================================
SUMMARY
