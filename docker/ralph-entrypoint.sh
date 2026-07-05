#!/usr/bin/env bash
set -euo pipefail
# Container entrypoint: raise the egress firewall as root, then drop to the
# non-root 'ralph' user and exec claude with the args ralph.sh passed as the
# container command. The iteration prompt arrives on stdin from /prompt.txt
# (opened before the privilege drop, so its permissions don't matter).

if [ "${RALPH_FIREWALL:-on}" = "on" ]; then
  /usr/local/bin/init-firewall.sh
else
  echo "firewall: DISABLED (RALPH_FIREWALL=off)" >&2
fi

exec setpriv --reuid ralph --regid ralph --init-groups \
  env HOME=/home/ralph PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  stdbuf -oL claude "$@" < /prompt.txt
