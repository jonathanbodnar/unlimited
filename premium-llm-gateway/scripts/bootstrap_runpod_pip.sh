#!/usr/bin/env bash
# =============================================================================
# bootstrap_runpod_pip.sh — set up the LiteLLM proxy on a vLLM-template
# RunPod pod that does NOT have Docker.
#
# Why this exists:
#   The vLLM RunPod base images are not privileged containers, so we can't
#   run docker-in-docker. This script installs LiteLLM as a Python process
#   alongside a local Postgres whose data lives on the persistent /workspace
#   volume, so spend logs and virtual keys survive pod stop/start cycles.
#
# What it installs (idempotent — safe to re-run after a pod restart):
#   apt: git python3-venv python3-pip postgresql tmux openssl wget jq
#   /workspace/unlimited                  (this repo)
#   /workspace/litellm-venv               (python venv with litellm[proxy])
#   /workspace/postgres-data              (PG cluster data, persistent)
#   /workspace/litellm-state              (.env, runtime files)
#   /workspace/bin/cloudflared            (used to expose port 4000 publicly
#                                          if the RunPod template doesn't
#                                          have an HTTP port mapped)
#
# After this runs, secrets still need to be filled in. See:
#   /workspace/litellm-state/.env.template
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/jonathanbodnar/unlimited.git}"
REPO_DIR="${REPO_DIR:-/workspace/unlimited}"
GATEWAY_DIR="${REPO_DIR}/premium-llm-gateway"
VENV_DIR="${VENV_DIR:-/workspace/litellm-venv}"
PG_DATA="${PG_DATA:-/workspace/postgres-data}"
PG_PORT="${PG_PORT:-5433}"   # avoid clashing with anything system-default
PG_RUN="${PG_RUN:-/workspace/postgres-run}"
STATE_DIR="${STATE_DIR:-/workspace/litellm-state}"
BIN_DIR="${BIN_DIR:-/workspace/bin}"
CLOUDFLARED_BIN="${BIN_DIR}/cloudflared"

LITELLM_DB="${LITELLM_DB:-litellm}"
LITELLM_DB_USER="${LITELLM_DB_USER:-litellm}"

log()  { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[bootstrap] ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[bootstrap] warn\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[bootstrap] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1) System packages
# -----------------------------------------------------------------------------
log "apt-get update / install (git, python3-venv, pip, postgresql, tmux, openssl, jq, wget)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -yq --no-install-recommends \
  git python3 python3-venv python3-pip \
  postgresql postgresql-client \
  tmux openssl wget curl ca-certificates jq \
  build-essential libpq-dev \
  >/dev/null
ok "apt deps present"

# -----------------------------------------------------------------------------
# 2) Repo
# -----------------------------------------------------------------------------
mkdir -p /workspace
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  log "cloning ${REPO_URL} -> ${REPO_DIR}"
  git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
else
  log "pulling latest in ${REPO_DIR}"
  git -C "${REPO_DIR}" fetch --quiet --all
  git -C "${REPO_DIR}" reset --hard --quiet origin/main || true
fi
[[ -d "${GATEWAY_DIR}" ]] || fail "expected ${GATEWAY_DIR} after clone"
ok "repo at ${REPO_DIR} ($(git -C "${REPO_DIR}" rev-parse --short HEAD))"

# -----------------------------------------------------------------------------
# 3) Python venv + litellm[proxy]
# -----------------------------------------------------------------------------
if [[ ! -d "${VENV_DIR}" ]]; then
  log "creating venv at ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --quiet --upgrade pip
log "installing litellm[proxy] (large; may take a couple minutes)"
pip install --quiet \
  'litellm[proxy]==1.55.4' \
  prisma==0.15.0 \
  asyncpg==0.30.0
ok "litellm $(litellm --version 2>/dev/null | head -1 || echo installed)"

# -----------------------------------------------------------------------------
# 4) Local Postgres on /workspace (persistent)
# -----------------------------------------------------------------------------
PG_BIN_DIR="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
[[ -x "${PG_BIN_DIR}/initdb" ]] || fail "could not find initdb under /usr/lib/postgresql/*/bin"
log "using postgres binaries from ${PG_BIN_DIR}"

mkdir -p "${PG_RUN}"
chown -R postgres:postgres "${PG_RUN}"

if [[ ! -s "${PG_DATA}/PG_VERSION" ]]; then
  log "initdb -> ${PG_DATA}"
  mkdir -p "${PG_DATA}"
  chown -R postgres:postgres "${PG_DATA}"
  chmod 700 "${PG_DATA}"
  sudo -u postgres "${PG_BIN_DIR}/initdb" -D "${PG_DATA}" \
    --auth-local=trust --auth-host=md5 \
    --encoding=UTF8 --locale=C >/dev/null
  ok "postgres cluster initialized"
fi
chown -R postgres:postgres "${PG_DATA}" "${PG_RUN}"

# Configure cluster: bind to localhost on PG_PORT, write socket to PG_RUN.
cat > "${PG_DATA}/postgresql.auto.conf" <<EOF
listen_addresses = '127.0.0.1'
port = ${PG_PORT}
unix_socket_directories = '${PG_RUN}'
log_destination = 'stderr'
logging_collector = off
EOF
chown postgres:postgres "${PG_DATA}/postgresql.auto.conf"

# Allow loopback md5 auth.
PG_HBA="${PG_DATA}/pg_hba.conf"
if ! grep -q '^host  *all  *all  *127.0.0.1/32  *md5' "${PG_HBA}" 2>/dev/null; then
  cat >> "${PG_HBA}" <<EOF
host  all  all  127.0.0.1/32  md5
host  all  all  ::1/128       md5
EOF
fi
chown postgres:postgres "${PG_HBA}"

# Start (or restart) postgres.
PG_PID_FILE="${PG_DATA}/postmaster.pid"
if [[ -f "${PG_PID_FILE}" ]] \
    && kill -0 "$(head -1 "${PG_PID_FILE}")" 2>/dev/null; then
  log "postgres already running (pid $(head -1 "${PG_PID_FILE}"))"
else
  log "starting postgres on ${PG_PORT}"
  sudo -u postgres "${PG_BIN_DIR}/pg_ctl" -D "${PG_DATA}" \
    -l "${PG_DATA}/postgres.log" -w start
fi

# Make sure we can talk to it.
for i in $(seq 1 15); do
  if sudo -u postgres "${PG_BIN_DIR}/psql" -h "${PG_RUN}" -p "${PG_PORT}" \
       -d postgres -c 'select 1' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Create role + db with random password if not present.
mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
PG_PW_FILE="${STATE_DIR}/.pg_password"
if [[ ! -f "${PG_PW_FILE}" ]]; then
  openssl rand -hex 24 > "${PG_PW_FILE}"
  chmod 600 "${PG_PW_FILE}"
fi
PG_PW="$(cat "${PG_PW_FILE}")"

# Idempotent role/db creation. Use heredoc through psql.
sudo -u postgres "${PG_BIN_DIR}/psql" -h "${PG_RUN}" -p "${PG_PORT}" \
  -v ON_ERROR_STOP=1 -d postgres <<SQL >/dev/null
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${LITELLM_DB_USER}') THEN
    CREATE ROLE ${LITELLM_DB_USER} LOGIN PASSWORD '${PG_PW}';
  ELSE
    ALTER ROLE ${LITELLM_DB_USER} WITH LOGIN PASSWORD '${PG_PW}';
  END IF;
END \$\$;
SQL

if ! sudo -u postgres "${PG_BIN_DIR}/psql" -h "${PG_RUN}" -p "${PG_PORT}" \
       -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname = '${LITELLM_DB}'" \
       | grep -q 1; then
  sudo -u postgres "${PG_BIN_DIR}/createdb" -h "${PG_RUN}" -p "${PG_PORT}" \
    -O "${LITELLM_DB_USER}" "${LITELLM_DB}"
fi
ok "postgres ready: ${LITELLM_DB} owned by ${LITELLM_DB_USER} on 127.0.0.1:${PG_PORT}"

# -----------------------------------------------------------------------------
# 5) State / .env scaffold
# -----------------------------------------------------------------------------
DATABASE_URL="postgresql://${LITELLM_DB_USER}:${PG_PW}@127.0.0.1:${PG_PORT}/${LITELLM_DB}"

ENV_TEMPLATE="${STATE_DIR}/.env.template"
ENV_FILE="${STATE_DIR}/.env"

# Stable secrets we generate on first run.
LITELLM_KEY_FILE="${STATE_DIR}/.litellm_master_key"
if [[ ! -f "${LITELLM_KEY_FILE}" ]]; then
  echo "sk-admin-$(openssl rand -hex 24)" > "${LITELLM_KEY_FILE}"
  chmod 600 "${LITELLM_KEY_FILE}"
fi
LITELLM_MASTER_KEY="$(cat "${LITELLM_KEY_FILE}")"

cat > "${ENV_TEMPLATE}" <<EOF
# Auto-generated by bootstrap_runpod_pip.sh. Do NOT commit.
# Copy to .env and fill in the model-provider keys.

DATABASE_URL=${DATABASE_URL}
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}

DEEPSEEK_API_KEY=
MIMO_API_KEY=
ANTHROPIC_API_KEY=
OPENAI_API_KEY=

LANGFUSE_PUBLIC_KEY=
LANGFUSE_SECRET_KEY=
LANGFUSE_HOST=https://cloud.langfuse.com

ACTIVE_MODE=A
EOF
chmod 600 "${ENV_TEMPLATE}"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_TEMPLATE}" "${ENV_FILE}"
  ok "wrote ${ENV_FILE} (provider keys still need filling in)"
else
  ok "${ENV_FILE} already present (left untouched)"
fi

# -----------------------------------------------------------------------------
# 6) cloudflared (optional public-URL helper)
# -----------------------------------------------------------------------------
mkdir -p "${BIN_DIR}"
if [[ ! -x "${CLOUDFLARED_BIN}" ]]; then
  log "downloading cloudflared"
  wget -q -O "${CLOUDFLARED_BIN}" \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "${CLOUDFLARED_BIN}"
fi
ok "cloudflared at ${CLOUDFLARED_BIN}"

# -----------------------------------------------------------------------------
# 7) Summary
# -----------------------------------------------------------------------------
cat <<SUMMARY

==============================================================================
Bootstrap complete.

Persistent state:
  repo:           ${REPO_DIR}
  venv:           ${VENV_DIR}
  postgres data:  ${PG_DATA}    (port ${PG_PORT})
  state dir:      ${STATE_DIR}
  cloudflared:    ${CLOUDFLARED_BIN}

LiteLLM master key (also in ${LITELLM_KEY_FILE}):
  ${LITELLM_MASTER_KEY}

Postgres connection (also in ${ENV_FILE} as DATABASE_URL):
  ${DATABASE_URL}

Next:
  1. Fill in the provider keys in:
       ${ENV_FILE}
     i.e. MIMO_API_KEY, DEEPSEEK_API_KEY, LANGFUSE_PUBLIC_KEY,
     LANGFUSE_SECRET_KEY, optional ANTHROPIC_API_KEY.

  2. Update ${GATEWAY_DIR}/litellm_config.yaml — replace
     the REPLACE_WITH_… placeholders with the real provider base URLs
     and model names.

  3. Start LiteLLM (use scripts/run_litellm.sh — written next).
==============================================================================
SUMMARY
