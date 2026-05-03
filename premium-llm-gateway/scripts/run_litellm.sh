#!/usr/bin/env bash
# =============================================================================
# run_litellm.sh — start (or restart) LiteLLM + a public cloudflared tunnel
# inside detached tmux sessions on a RunPod pod that ran bootstrap_runpod_pip.sh.
#
# Usage:
#   ./scripts/run_litellm.sh start    # start litellm + tunnel
#   ./scripts/run_litellm.sh stop     # kill both tmux sessions
#   ./scripts/run_litellm.sh status   # show what's running + the public URL
#   ./scripts/run_litellm.sh logs     # tail litellm logs
#   ./scripts/run_litellm.sh url      # just print the cloudflared URL
#
# tmux sessions:
#   litellm    : the litellm proxy
#   tunnel     : cloudflared trycloudflare exposing port 4000
# =============================================================================

set -euo pipefail

REPO_DIR="${REPO_DIR:-/workspace/unlimited}"
GATEWAY_DIR="${GATEWAY_DIR:-${REPO_DIR}/premium-llm-gateway}"
VENV_DIR="${VENV_DIR:-/workspace/litellm-venv}"
STATE_DIR="${STATE_DIR:-/workspace/litellm-state}"
ENV_FILE="${STATE_DIR}/.env"
LOG_DIR="${STATE_DIR}/logs"
PORT="${PORT:-4000}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/workspace/bin/cloudflared}"

mkdir -p "${LOG_DIR}"
LITELLM_LOG="${LOG_DIR}/litellm.log"
TUNNEL_LOG="${LOG_DIR}/cloudflared.log"

cmd="${1:-status}"

is_running() { tmux has-session -t "$1" 2>/dev/null; }

start_litellm() {
  if is_running litellm; then
    echo "litellm tmux session already running"
    return 0
  fi
  [[ -f "${ENV_FILE}" ]] || { echo "missing ${ENV_FILE}; run bootstrap first" >&2; return 1; }
  [[ -d "${VENV_DIR}" ]] || { echo "missing ${VENV_DIR}; run bootstrap first" >&2; return 1; }
  [[ -f "${GATEWAY_DIR}/litellm_config.yaml" ]] \
    || { echo "missing ${GATEWAY_DIR}/litellm_config.yaml" >&2; return 1; }

  : > "${LITELLM_LOG}"
  tmux new-session -d -s litellm -c "${GATEWAY_DIR}" \
    "set -a; source '${ENV_FILE}'; set +a; \
     source '${VENV_DIR}/bin/activate'; \
     exec litellm \
       --config '${GATEWAY_DIR}/litellm_config.yaml' \
       --port ${PORT} --host 0.0.0.0 \
       2>&1 | tee -a '${LITELLM_LOG}'"
  echo "litellm started in tmux (session=litellm, port=${PORT}, log=${LITELLM_LOG})"
}

start_tunnel() {
  if is_running tunnel; then
    echo "cloudflared tmux session already running"
    return 0
  fi
  [[ -x "${CLOUDFLARED_BIN}" ]] \
    || { echo "missing ${CLOUDFLARED_BIN}; run bootstrap first" >&2; return 1; }
  : > "${TUNNEL_LOG}"
  tmux new-session -d -s tunnel \
    "exec ${CLOUDFLARED_BIN} tunnel --no-autoupdate \
       --url http://localhost:${PORT} 2>&1 | tee -a '${TUNNEL_LOG}'"
  echo "cloudflared started in tmux (session=tunnel, log=${TUNNEL_LOG})"
}

print_tunnel_url() {
  for i in $(seq 1 30); do
    if [[ -s "${TUNNEL_LOG}" ]]; then
      url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "${TUNNEL_LOG}" \
              | head -1 || true)
      if [[ -n "${url:-}" ]]; then
        echo "${url}"
        return 0
      fi
    fi
    sleep 1
  done
  echo "(tunnel URL not yet visible in ${TUNNEL_LOG} — check it manually)" >&2
  return 1
}

stop_all() {
  for s in litellm tunnel; do
    if is_running "${s}"; then
      tmux kill-session -t "${s}"
      echo "stopped ${s}"
    fi
  done
}

case "${cmd}" in
  start)
    start_litellm
    start_tunnel
    echo
    echo "Public URL (paste into Railway as LITELLM_URL):"
    print_tunnel_url || true
    echo
    echo "Master key (paste into Railway as LITELLM_MASTER_KEY):"
    grep -E '^LITELLM_MASTER_KEY=' "${ENV_FILE}" | cut -d= -f2-
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    sleep 1
    start_litellm
    start_tunnel
    print_tunnel_url || true
    ;;
  status)
    for s in litellm tunnel; do
      if is_running "${s}"; then echo "${s}: running"; else echo "${s}: stopped"; fi
    done
    echo
    echo "Public URL:"
    print_tunnel_url || true
    ;;
  url)
    print_tunnel_url
    ;;
  logs)
    tail -F "${LITELLM_LOG}"
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|url|logs}" >&2
    exit 2
    ;;
esac
