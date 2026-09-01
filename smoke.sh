#!/usr/bin/env bash
# smoke.sh — drive a full generate + launch + report cycle unattended.
#
# Exists so stack verification does not depend on a human copy-pasting compose
# output back into a chat window. Renders from scratch (never the "keep" path,
# which reuses a possibly-wedged generated/), brings the stack up, then reports
# per-container state and the logs of anything that did not survive.
set -uo pipefail

CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/configurator_v1" && pwd)"
GEN_DIR="${CFG_DIR}/generated"
WAIT_SECS="${SMOKE_WAIT:-45}"

cd "${CFG_DIR}" || exit 1

echo "== tearing down any previous stack =="
[ -f "${GEN_DIR}/docker-compose.yml" ] && \
  (cd "${GEN_DIR}" && docker compose down -v --remove-orphans >/dev/null 2>&1)

echo "== rendering (forced reset — never the keep path) =="
env F13_CONFIG_NONINTERACTIVE=1 F13_STATE_ACTION=reset F13_SKIP_PREFLIGHT=1 \
    F13_SKIP_BUILD="${F13_SKIP_BUILD:-1}" F13_SKIP_COMPOSE=1 \
    CHAT_BACKEND="${CHAT_BACKEND:-mock}" \
    FRONTEND_PORT="${FRONTEND_PORT:-9999}" CORE_PORT="${CORE_PORT:-8000}" \
    ./bin/f13-config >/tmp/f13-smoke-render.log 2>&1
rc=$?
[ $rc -ne 0 ] && { echo "RENDER FAILED (rc=$rc)"; tail -20 /tmp/f13-smoke-render.log; exit 1; }

# Every bind-mount source must be a regular file. Docker silently creates a
# DIRECTORY for a missing one, which then fails at runc with a confusing
# "not a directory" error -- catch it here where the message is actionable.
echo "== checking bind-mount sources are files =="
bad=0
while read -r src; do
  [ -z "$src" ] && continue
  p="${GEN_DIR}/${src#./}"
  if [ -d "$p" ]; then echo "  BAD (directory): $src"; bad=1; fi
done < <(grep -oE '^\s+- \./[^:]+\.(yaml|yml|rego|secret)' "${GEN_DIR}/docker-compose.yml" | sed 's/^[[:space:]]*- //')
[ $bad -eq 1 ] && { echo "ABORT: stray directories at mount sources"; exit 1; }
echo "  all mount sources OK"

echo "== compose up =="
(cd "${GEN_DIR}" && docker compose up -d >/tmp/f13-smoke-up.log 2>&1)
tail -3 /tmp/f13-smoke-up.log

echo "== settling ${WAIT_SECS}s =="
sleep "${WAIT_SECS}"

echo "== container state =="
docker ps -a --filter "label=com.docker.compose.project=generated" \
  --format '  {{.Names}}\t{{.State}}\t{{.Status}}'

echo "== logs for anything not running =="
for c in $(docker ps -a --filter "label=com.docker.compose.project=generated" \
           --filter "status=exited" --filter "status=restarting" --format '{{.Names}}'); do
  echo "--- $c ---"
  docker logs "$c" 2>&1 | tail -12 | sed 's/^/    /'
done
echo "== done =="
