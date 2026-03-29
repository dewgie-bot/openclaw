#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${OPENCLAW_FORK_BRANCH:-main}"
FORK_REMOTE="${OPENCLAW_FORK_REMOTE:-origin}"
UPSTREAM_REMOTE="${OPENCLAW_UPSTREAM_REMOTE:-upstream}"
ALLOW_ORIGIN_BEHIND="${OPENCLAW_UPDATE_FORK_ALLOW_BEHIND:-0}"

cd "${ROOT_DIR}"
export PATH="${ROOT_DIR}/node_modules/.bin:${PATH}"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

show_help() {
  cat <<EOF
Usage: scripts/update-fork.sh [openclaw update args...]

Fork-aware wrapper around \`openclaw update\`.

What it adds:
  - requires ${BRANCH} to track ${FORK_REMOTE}/${BRANCH}
  - checks whether ${FORK_REMOTE}/${BRANCH} is behind ${UPSTREAM_REMOTE}/${BRANCH}
  - allows inspection-oriented \`--dry-run\` even when the worktree is dirty
  - runs post-update smoke checks for built files and the live daemon
  - proves the gateway actually rotated onto a fresh runtime after restart

Examples:
  scripts/update-fork.sh
  scripts/update-fork.sh --dry-run
  scripts/update-fork.sh --no-restart

Environment overrides:
  OPENCLAW_FORK_BRANCH=${BRANCH}
  OPENCLAW_FORK_REMOTE=${FORK_REMOTE}
  OPENCLAW_UPSTREAM_REMOTE=${UPSTREAM_REMOTE}
  OPENCLAW_UPDATE_FORK_ALLOW_BEHIND=1
EOF
}

extract_gateway_fields() {
  local json="$1"
  node -e '
    const data = JSON.parse(process.argv[1]);
    const runtime = data.service?.runtime ?? {};
    const gateway = data.gateway ?? {};
    const health = data.health ?? {};
    const port = data.port ?? {};
    const values = [
      runtime.status ?? "",
      runtime.pid ?? "",
      gateway.bindMode ?? "",
      gateway.bindHost ?? "",
      gateway.port ?? "",
      gateway.probeUrl ?? "",
      health.healthy ?? "",
      port.status ?? "",
    ];
    process.stdout.write(`${values.map((value) => String(value ?? "")).join("\n")}\n`);
  ' "$json"
}

extract_status_fields() {
  local json="$1"
  node -e '
    const data = JSON.parse(process.argv[1]);
    const gateway = data.gateway ?? {};
    const values = [
      data.runtimeVersion ?? "",
      gateway.reachable ?? "",
      gateway.error ?? "",
      gateway.url ?? "",
    ];
    process.stdout.write(`${values.map((value) => String(value ?? "")).join("\n")}\n`);
  ' "$json"
}

get_process_start_time() {
  local pid="${1:-}"
  if [[ -z "${pid}" || "${pid}" == "null" ]]; then
    return 0
  fi
  ps -p "${pid}" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' | head -n 1 || true
}

capture_gateway_state() {
  local json
  json="$(node openclaw.mjs gateway status --json --no-probe)"
  local -a gateway_fields
  while IFS= read -r line; do
    gateway_fields+=("${line}")
  done < <(extract_gateway_fields "${json}")
  local runtime_status="${gateway_fields[0]:-}"
  local pid="${gateway_fields[1]:-}"
  local bind_mode="${gateway_fields[2]:-}"
  local bind_host="${gateway_fields[3]:-}"
  local port="${gateway_fields[4]:-}"
  local probe_url="${gateway_fields[5]:-}"
  local healthy="${gateway_fields[6]:-}"
  local start_time
  start_time="$(get_process_start_time "${pid}")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${runtime_status}" \
    "${pid}" \
    "${start_time}" \
    "${bind_mode}" \
    "${bind_host}" \
    "${port}" \
    "${probe_url}" \
    "${healthy}"
}

resolve_http_url() {
  local probe_url="${1:-}"
  local bind_host="${2:-}"
  local port="${3:-}"
  if [[ -n "${probe_url}" ]]; then
    case "${probe_url}" in
      ws://*) printf '%s\n' "http://${probe_url#ws://}/" ;;
      wss://*) printf '%s\n' "https://${probe_url#wss://}/" ;;
      *) printf '%s\n' "${probe_url}" ;;
    esac
    return 0
  fi

  local host="${bind_host}"
  if [[ -z "${host}" || "${host}" == "0.0.0.0" || "${host}" == "::" || "${host}" == "[::]" ]]; then
    host="127.0.0.1"
  fi
  printf 'http://%s:%s/\n' "${host}" "${port}"
}

NO_RESTART=0
DRY_RUN=0
FORWARDED_ARGS=()

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      exit 0
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
  esac
  FORWARDED_ARGS+=("$arg")
done

current_branch="$(git branch --show-current)"
if [[ "${current_branch}" != "${BRANCH}" ]]; then
  die "expected current branch ${BRANCH}, got ${current_branch:-detached-head}"
fi

tracking_branch="$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
expected_tracking="${FORK_REMOTE}/${BRANCH}"
if [[ "${tracking_branch}" != "${expected_tracking}" ]]; then
  die "expected ${BRANCH} to track ${expected_tracking}; run: git branch --set-upstream-to ${expected_tracking} ${BRANCH}"
fi

dirty="$(git status --porcelain -- ':!dist/control-ui/' ':!.bundle-stats.html')"
if [[ -n "${dirty}" && "${DRY_RUN}" != "1" ]]; then
  die "worktree is dirty; commit or stash changes before updating"
fi
if [[ -n "${dirty}" && "${DRY_RUN}" == "1" ]]; then
  # A dry run is inspection-only, so it should still be useful while you're
  # mid-fix. The real update path keeps the clean-tree guard.
  log "Dry run: worktree is dirty, but inspection is allowed"
fi

log "Fetching remotes"
git fetch --all --prune --tags

origin_ahead_of_upstream=""
origin_behind_upstream=""
if git rev-parse --verify "${UPSTREAM_REMOTE}/${BRANCH}" >/dev/null 2>&1; then
  upstream_vs_origin="$(git rev-list --left-right --count "${UPSTREAM_REMOTE}/${BRANCH}...${FORK_REMOTE}/${BRANCH}")"
  IFS=$' \t' read -r origin_behind_upstream origin_ahead_of_upstream <<< "${upstream_vs_origin}"
  if [[ "${origin_behind_upstream}" != "0" && "${ALLOW_ORIGIN_BEHIND}" != "1" ]]; then
    die "${FORK_REMOTE}/${BRANCH} is behind ${UPSTREAM_REMOTE}/${BRANCH} by ${origin_behind_upstream} commit(s); merge upstream into your fork first or rerun with OPENCLAW_UPDATE_FORK_ALLOW_BEHIND=1"
  fi
  log "${FORK_REMOTE}/${BRANCH} vs ${UPSTREAM_REMOTE}/${BRANCH}: behind=${origin_behind_upstream} ahead=${origin_ahead_of_upstream}"
fi

local_vs_origin="$(git rev-list --left-right --count "HEAD...${FORK_REMOTE}/${BRANCH}")"
IFS=$' \t' read -r local_ahead_of_origin local_behind_origin <<< "${local_vs_origin}"
log "Local ${BRANCH} vs ${FORK_REMOTE}/${BRANCH}: ahead=${local_ahead_of_origin} behind=${local_behind_origin}"

BEFORE_GATEWAY_STATUS=""
BEFORE_GATEWAY_PID=""
BEFORE_GATEWAY_START=""
BEFORE_GATEWAY_BIND_MODE=""
BEFORE_GATEWAY_BIND_HOST=""
BEFORE_GATEWAY_PORT=""
BEFORE_GATEWAY_PROBE_URL=""
BEFORE_GATEWAY_HEALTHY=""

IFS=$'\t' read -r \
  BEFORE_GATEWAY_STATUS \
  BEFORE_GATEWAY_PID \
  BEFORE_GATEWAY_START \
  BEFORE_GATEWAY_BIND_MODE \
  BEFORE_GATEWAY_BIND_HOST \
  BEFORE_GATEWAY_PORT \
  BEFORE_GATEWAY_PROBE_URL \
  BEFORE_GATEWAY_HEALTHY <<< "$(capture_gateway_state)"

log "Running fork update via openclaw update"
node openclaw.mjs update "${FORWARDED_ARGS[@]}"

CLI_VERSION="$(node openclaw.mjs --version)"
STATUS_JSON="$(node openclaw.mjs status --json)"
status_fields=()
while IFS= read -r line; do
  status_fields+=("${line}")
done < <(extract_status_fields "${STATUS_JSON}")
STATUS_RUNTIME_VERSION="${status_fields[0]:-}"
STATUS_GATEWAY_REACHABLE="${status_fields[1]:-}"
STATUS_GATEWAY_ERROR="${status_fields[2]:-}"
STATUS_GATEWAY_URL="${status_fields[3]:-}"

DIST_TUI_OK="skip"
DIST_STATUS_OK="skip"
LIVE_STATUS_OK="skip"
HTTP_OK="skip"
WS_OK="skip"
AFTER_GATEWAY_STATUS=""
AFTER_GATEWAY_PID=""
AFTER_GATEWAY_START=""
AFTER_GATEWAY_BIND_MODE=""
AFTER_GATEWAY_BIND_HOST=""
AFTER_GATEWAY_PORT=""
AFTER_GATEWAY_PROBE_URL=""
AFTER_GATEWAY_HEALTHY=""

if [[ "${DRY_RUN}" != "1" ]]; then
  log "Smoke-checking rebuilt TUI entry"
  node ./dist/index.js tui --help >/dev/null
  DIST_TUI_OK="ok"

  log "Smoke-checking built CLI status entry"
  node ./dist/index.js status >/dev/null
  DIST_STATUS_OK="ok"

  log "Smoke-checking live CLI status entry"
  node openclaw.mjs status >/dev/null
  LIVE_STATUS_OK="ok"
fi

if [[ "${NO_RESTART}" == "0" && "${DRY_RUN}" != "1" ]]; then
  IFS=$'\t' read -r \
    AFTER_GATEWAY_STATUS \
    AFTER_GATEWAY_PID \
    AFTER_GATEWAY_START \
    AFTER_GATEWAY_BIND_MODE \
    AFTER_GATEWAY_BIND_HOST \
    AFTER_GATEWAY_PORT \
    AFTER_GATEWAY_PROBE_URL \
    AFTER_GATEWAY_HEALTHY <<< "$(capture_gateway_state)"

  if [[ "${AFTER_GATEWAY_STATUS}" != "running" || -z "${AFTER_GATEWAY_PID}" ]]; then
    die "gateway was expected to restart, but no running daemon was detected afterward"
  fi

  if [[ -n "${BEFORE_GATEWAY_PID}" ]]; then
    if [[ "${AFTER_GATEWAY_PID}" == "${BEFORE_GATEWAY_PID}" ]]; then
      if [[ -n "${BEFORE_GATEWAY_START}" && -n "${AFTER_GATEWAY_START}" ]]; then
        if [[ "${AFTER_GATEWAY_START}" == "${BEFORE_GATEWAY_START}" ]]; then
          die "gateway restart was expected, but the daemon still appears to be the same process (pid ${AFTER_GATEWAY_PID}, start ${AFTER_GATEWAY_START})"
        fi
      else
        die "gateway restart was expected, but the daemon PID did not change and process start time could not prove rotation (pid ${AFTER_GATEWAY_PID})"
      fi
    fi
  fi

  http_url="$(resolve_http_url "${AFTER_GATEWAY_PROBE_URL}" "${AFTER_GATEWAY_BIND_HOST}" "${AFTER_GATEWAY_PORT}")"

  log "Waiting for gateway HTTP health at ${http_url}"
  for _ in {1..15}; do
    if curl -fsS "${http_url}" >/dev/null 2>&1; then
      HTTP_OK="ok"
      break
    fi
    sleep 1
  done
  if [[ "${HTTP_OK}" != "ok" ]]; then
    die "gateway HTTP check failed after restart (${http_url})"
  fi

  log "Waiting for gateway WebSocket health at ${AFTER_GATEWAY_PROBE_URL}"
  if OPENCLAW_GATEWAY_PROBE_URL="${AFTER_GATEWAY_PROBE_URL}" node <<'EOF'
const url = process.env.OPENCLAW_GATEWAY_PROBE_URL;
const ws = new WebSocket(url);
const timer = setTimeout(() => {
  console.error(`gateway websocket timeout (${url})`);
  process.exit(1);
}, 5000);

ws.onopen = () => {
  clearTimeout(timer);
  ws.close();
};

ws.onclose = () => {
  process.exit(0);
};

ws.onerror = () => {
  clearTimeout(timer);
  console.error(`gateway websocket error (${url})`);
  process.exit(1);
};
EOF
  then
    WS_OK="ok"
  else
    die "gateway WebSocket check failed after restart (${AFTER_GATEWAY_PROBE_URL})"
  fi
fi

printf '\nVerification summary\n'
printf '  branch: %s\n' "${current_branch}"
printf '  tracking: %s\n' "${tracking_branch}"
printf '  local vs %s: ahead=%s behind=%s\n' "${FORK_REMOTE}/${BRANCH}" "${local_ahead_of_origin}" "${local_behind_origin}"
if [[ -n "${origin_behind_upstream}" || -n "${origin_ahead_of_upstream}" ]]; then
  printf '  %s vs %s: ahead=%s behind=%s\n' \
    "${FORK_REMOTE}/${BRANCH}" \
    "${UPSTREAM_REMOTE}/${BRANCH}" \
    "${origin_ahead_of_upstream:-0}" \
    "${origin_behind_upstream:-0}"
fi
printf '  cli version: %s\n' "${CLI_VERSION}"
printf '  status runtime version: %s\n' "${STATUS_RUNTIME_VERSION}"
printf '  status gateway: reachable=%s url=%s error=%s\n' \
  "${STATUS_GATEWAY_REACHABLE}" \
  "${STATUS_GATEWAY_URL}" \
  "${STATUS_GATEWAY_ERROR:-none}"
printf '  dist tui smoke: %s\n' "${DIST_TUI_OK}"
printf '  dist status smoke: %s\n' "${DIST_STATUS_OK}"
printf '  live status smoke: %s\n' "${LIVE_STATUS_OK}"
printf '  gateway pid: before=%s after=%s\n' "${BEFORE_GATEWAY_PID:-none}" "${AFTER_GATEWAY_PID:-skip}"
printf '  gateway start: before=%s after=%s\n' "${BEFORE_GATEWAY_START:-none}" "${AFTER_GATEWAY_START:-skip}"
printf '  gateway probe url: before=%s after=%s\n' "${BEFORE_GATEWAY_PROBE_URL:-none}" "${AFTER_GATEWAY_PROBE_URL:-skip}"
printf '  gateway http: %s\n' "${HTTP_OK}"
printf '  gateway ws: %s\n' "${WS_OK}"

log "Fork update completed"
