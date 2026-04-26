#!/usr/bin/env bash
# ralph-dashboard.sh -Live cost and progress dashboard for the Ralph loop.
# Refreshes every N minutes (default 10). Ctrl-C to quit.
#
# Usage: ./ralph-dashboard.sh [workdir] [refresh_minutes]

WORKDIR="${1:-configurator_v1}"
REFRESH="${2:-10}"
STORIES_TOTAL=45  # keep in sync with ralph.sh
case "$REFRESH" in
  0) REFRESH_SECS=0 ;;  # one-shot mode: render once and exit
  1|5|10|20|30|60) REFRESH_SECS=$(( REFRESH * 60 )) ;;
  *) echo "Refresh must be 0 (once), 1, 5, 10, 20, 30, or 60 (minutes). Default: 10"; REFRESH=10; REFRESH_SECS=600 ;;
esac
LOGDIR="$WORKDIR/ralph-logs"
W=63  # inner width of the box (for printf padding of ASCII content)

# ── Colors ──
C='\033[0;36m'    # cyan (borders)
G='\033[0;32m'    # green
Y='\033[1;33m'    # yellow
R='\033[0;31m'    # red
B='\033[1m'       # bold
D='\033[2m'       # dim
N='\033[0m'       # reset

if [ ! -d "$LOGDIR" ]; then
  echo -e "${R}No logs found at $LOGDIR${N}"
  exit 1
fi

trap 'printf "\n"; exit 0' INT

# ── Helpers ──
fmt_tokens() {
  local t=$1
  if [ "$t" -ge 1000000 ]; then
    printf "%d.%dM" "$(( t / 1000000 ))" "$(( (t % 1000000) / 100000 ))"
  elif [ "$t" -ge 1000 ]; then
    printf "%dK" "$(( t / 1000 ))"
  else
    printf "%d" "$t"
  fi
}

fmt_cost() {
  printf "\$%d.%02d" "$(( $1 / 100 ))" "$(( $1 % 100 ))"
}

# Print a line inside the box: row "content"
# Pads content to W chars, wraps with colored borders
row() {
  printf "${C}║${N}%-${W}s${C}║${N}\n" " $1"
}

rowb() {
  printf "${C}║${N}${B}%-${W}s${N}${C}║${N}\n" " $1"
}

sep() {
  printf "${C}╠"
  printf '═%.0s' $(seq 1 $W)
  printf "╣${N}\n"
}

top() {
  printf "${C}╔"
  printf '═%.0s' $(seq 1 $W)
  printf "╗${N}\n"
}

bot() {
  printf "${C}╚"
  printf '═%.0s' $(seq 1 $W)
  printf "╝${N}\n"
}

# ── Opus pricing per 1M tokens (in cents) ──
P_IN=1500
P_OUT=7500
P_CR=150
P_CC=375

while true; do
clear

# ── Gather data ──
total_input=0
total_output=0
total_cache_read=0
total_cache_create=0
total_cost=0
iteration_count=0
iter_costs=()

for uf in "$LOGDIR"/usage-*.json; do
  [ -f "$uf" ] || continue
  iteration_count=$(( iteration_count + 1 ))
  input=$(grep -o '"input_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*')
  output=$(grep -o '"output_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*')
  cache_read=$(grep -o '"cache_read_input_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*')
  cache_create=$(grep -o '"cache_creation_input_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*')
  cost=$(grep -o '"cost_cents": *[0-9]*' "$uf" | grep -o '[0-9]*')
  total_input=$(( total_input + ${input:-0} ))
  total_output=$(( total_output + ${output:-0} ))
  total_cache_read=$(( total_cache_read + ${cache_read:-0} ))
  total_cache_create=$(( total_cache_create + ${cache_create:-0} ))
  total_cost=$(( total_cost + ${cost:-0} ))
  iter_name=$(basename "$uf" .json | sed 's/usage-//')
  iter_costs+=("${cost:-0}:${iter_name}")
done

stories_done="$( (grep '^| S[0-9]' "$WORKDIR/PROGRESS.md" 2>/dev/null || true) | wc -l | tr -d ' ')"
stories_total=$STORIES_TOTAL
stories_pending=$(( stories_total - stories_done ))
[ "$stories_pending" -lt 0 ] && stories_pending=0
commit_count=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
first_commit=$(git -C "$WORKDIR" log --reverse --format='%ci' 2>/dev/null | head -1)
last_commit=$(git -C "$WORKDIR" log -1 --format='%ci' 2>/dev/null)
src_files=$(find "$WORKDIR/bin" "$WORKDIR/lib" -type f -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
test_files=$(find "$WORKDIR/tests" -type f -name "*.bats" 2>/dev/null | wc -l | tr -d ' ')

cost_input=$(( total_input * P_IN / 1000000 ))
cost_output=$(( total_output * P_OUT / 1000000 ))
cost_cache_read=$(( total_cache_read * P_CR / 1000000 ))
cost_cache_create=$(( total_cache_create * P_CC / 1000000 ))

avg_cost=0; [ "$iteration_count" -gt 0 ] && avg_cost=$(( total_cost / iteration_count ))
avg_story=0; [ "$stories_done" -gt 0 ] && avg_story=$(( total_cost / stories_done ))

IFS=$'\n' sorted=($(printf '%s\n' "${iter_costs[@]}" | sort -t: -k1 -rn | head -5))
unset IFS

# ── Render ──
echo ""
top
rowb "        Ralph Loop - Cost & Progress Dashboard"
sep
row ""
row "$(printf 'Stories completed:  %d / %d' "$stories_done" "$stories_total")"
row "$(printf 'Stories pending:    %d' "$stories_pending")"
row "$(printf 'Total commits:      %d' "$commit_count")"
row "$(printf 'Iterations tracked: %d' "$iteration_count")"
row "$(printf 'Shell scripts:      %d  (bats tests: %d)' "${src_files:-0}" "${test_files:-0}")"
row ""
row "$(printf 'First commit:  %s' "${first_commit:0:19}")"
row "$(printf 'Last commit:   %s' "${last_commit:0:19}")"
row ""
sep
rowb "  Token Usage & Cost (Opus API Pricing)"
sep
row ""
row "$(printf '%-24s %8s tokens   %s' 'Input (uncached):' "$(fmt_tokens $total_input)" "$(fmt_cost $cost_input)")"
row "$(printf '%-24s %8s tokens   %s' 'Output:' "$(fmt_tokens $total_output)" "$(fmt_cost $cost_output)")"
row "$(printf '%-24s %8s tokens   %s' 'Cache read:' "$(fmt_tokens $total_cache_read)" "$(fmt_cost $cost_cache_read)")"
row "$(printf '%-24s %8s tokens   %s' 'Cache creation:' "$(fmt_tokens $total_cache_create)" "$(fmt_cost $cost_cache_create)")"
row "                                    -------------"
rowb "$(printf '%-24s              %s' 'TOTAL COST:' "$(fmt_cost $total_cost)")"
row ""
row "$(printf 'Avg per iteration:  %s' "$(fmt_cost $avg_cost)")"
row "$(printf 'Avg per story:      %s' "$(fmt_cost $avg_story)")"
row ""

if [ ${#sorted[@]} -gt 0 ]; then
  sep
  rowb "  Most Expensive Iterations"
  sep
  row ""
  for entry in "${sorted[@]}"; do
    c=$(echo "$entry" | cut -d: -f1)
    n=$(echo "$entry" | cut -d: -f2)
    row "$(printf '  Iteration %-6s %s' "$n" "$(fmt_cost $c)")"
  done
  row ""
fi

if [ "$stories_done" -gt 0 ] && [ "$stories_pending" -gt 0 ] && [ "$total_cost" -gt 0 ]; then
  projected=$(( total_cost * stories_total / stories_done ))
  remaining=$(( projected - total_cost ))
  sep
  rowb "  Projection"
  sep
  row ""
  row "$(printf 'Estimated total:    %s  (all %d stories)' "$(fmt_cost $projected)" "$stories_total")"
  row "$(printf 'Remaining est.:     %s  (%d stories left)' "$(fmt_cost $remaining)" "$stories_pending")"
  row ""
fi

bot
echo ""

# One-shot mode: render once and exit
if [ "$REFRESH_SECS" -eq 0 ]; then
  exit 0
fi

echo -e "${D}  Refreshing every ${REFRESH}m · Enter to reload · q/quit to exit · $(date '+%H:%M:%S')${N}"

read -t "$REFRESH_SECS" -r input 2>/dev/null || true
case "${input:-}" in
  q|/q|quit) printf "\n"; exit 0 ;;
esac
done
