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

# ralph's primary group may be a pre-existing system group (e.g. host
# gid 20 = dialout on Debian), so resolve it numerically — a literal
# "--regid ralph" fails when no group of that name exists.
ralph_gid="$(id -g ralph)"
exec setpriv --reuid ralph --regid "$ralph_gid" --init-groups \
  env HOME=/home/ralph PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  stdbuf -oL claude "$@" < /prompt.txt
