#!/usr/bin/env bash
set -euo pipefail
# Egress allowlist for the Ralph sandbox container. Runs as root at container
# start, before ralph-entrypoint.sh drops privileges to the non-root 'ralph'
# user — after the drop the agent has no capabilities and cannot undo rules.
#
# Allowed egress (HTTPS only):
#   api.anthropic.com               Claude API
#   registry.npmjs.org              npm run check / vitest deps (GUI backpressure)
#   crates.io + static/index        cargo check deps (GUI backpressure)
#   $RALPH_NET_ALLOW_EXTRA          operator additions (space-separated domains)
# apt is NOT allowed — all toolchain deps are baked into the image.

ALLOWED_DOMAINS="api.anthropic.com registry.npmjs.org crates.io static.crates.io index.crates.io ${RALPH_NET_ALLOW_EXTRA:-}"

ipset destroy ralph-allow 2>/dev/null || true
ipset create ralph-allow hash:net

for domain in $ALLOWED_DOMAINS; do
  ips=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [ -z "$ips" ]; then
    echo "firewall WARN: no A records for $domain" >&2
    continue
  fi
  for ip in $ips; do
    ipset add ralph-allow "$ip" -exist
  done
done

iptables -F OUTPUT
iptables -F INPUT
# loopback (also carries Docker's embedded DNS at 127.0.0.11)
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
# DNS only to the configured resolvers
while read -r _ ns; do
  iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done < <(grep '^nameserver' /etc/resolv.conf)
# replies to established flows
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# HTTPS to the allowlist only
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set ralph-allow dst -j ACCEPT
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP

# IPv6: the allowlist is v4-only, so drop v6 entirely (loopback excepted).
# Without this, a host with container IPv6 egress would bypass the firewall.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -F INPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true
  ip6tables -P INPUT DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
fi

# Self-check: a non-allowlisted host must be unreachable, Anthropic must
# connect (any HTTP status counts — only the TCP/TLS path matters here).
if curl -s -m 5 https://example.com >/dev/null 2>&1; then
  echo "firewall ERR: self-check FAILED — example.com is reachable" >&2
  exit 1
fi
if ! curl -s -m 10 -o /dev/null https://api.anthropic.com; then
  echo "firewall ERR: self-check FAILED — api.anthropic.com unreachable" >&2
  exit 1
fi
echo "firewall: egress locked to allowlist" >&2
