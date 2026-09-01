#!/usr/bin/env bash
# ralph-live.sh — Parses Claude Code stream-json output into a human-readable live feed.
# Also accumulates token usage and writes a usage JSON file at the end.
#
# Usage: claude --output-format stream-json -p "..." | USAGE_FILE=path.json ./ralph-live.sh

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Token accumulators
model_id=""
total_input=0
total_output=0
total_cache_read=0
total_cache_create=0

# Usage output file (set by caller, e.g. USAGE_FILE=ralph-logs/usage-001.json)
USAGE_FILE="${USAGE_FILE:-/dev/null}"

extract() {
  # Fast field extraction: extract("field", "$line") -> value
  echo "$1" | grep -o "\"$2\":[0-9]*" | head -1 | grep -o '[0-9]*'
}

while IFS= read -r line; do
  # Authoritative session model, from the init event only. A bare grep for
  # '"model"' also matches background Haiku sub-calls and would pick the
  # wrong rate card.
  if [ -z "$model_id" ] && printf '%s' "$line" | grep -q '"subtype":"init"'; then
    model_id=$(printf '%s' "$line" | grep -o '"model":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi
  [ -z "$line" ] && continue

  type=$(echo "$line" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
  timestamp=$(date '+%H:%M:%S')

  # ── Accumulate token usage from every message that has it ──
  if echo "$line" | grep -q '"usage"'; then
    val=$(extract "$line" "input_tokens")
    [ -n "$val" ] && total_input=$(( total_input + val ))
    val=$(extract "$line" "output_tokens")
    [ -n "$val" ] && total_output=$(( total_output + val ))
    val=$(extract "$line" "cache_read_input_tokens")
    [ -n "$val" ] && total_cache_read=$(( total_cache_read + val ))
    val=$(extract "$line" "cache_creation_input_tokens")
    [ -n "$val" ] && total_cache_create=$(( total_cache_create + val ))
  fi

  # ── Live feed ──
  case "$type" in
    assistant)
      tool=$(echo "$line" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ -n "$tool" ]; then
        case "$tool" in
          Write|Edit)
            filepath=$(echo "$line" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -n "$filepath" ]; then
              short=$(echo "$filepath" | sed 's|.*/bin/|bin/|; s|.*/lib/|lib/|; s|.*/tests/|tests/|; s|.*/templates/|templates/|; s|.*/docs/|docs/|')
              echo -e "${CYAN}[$timestamp]${NC} ${GREEN}$tool${NC} $short"
            else
              echo -e "${CYAN}[$timestamp]${NC} ${GREEN}$tool${NC}"
            fi
            ;;
          Bash)
            cmd=$(echo "$line" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -n "$cmd" ]; then
              short_cmd=$(echo "$cmd" | cut -c1-100)
              echo -e "${CYAN}[$timestamp]${NC} ${YELLOW}Run${NC} $short_cmd"
            fi
            ;;
          Read)
            filepath=$(echo "$line" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -n "$filepath" ]; then
              short=$(echo "$filepath" | sed 's|.*/bin/|bin/|; s|.*/lib/|lib/|; s|.*/tests/|tests/|; s|.*/templates/|templates/|; s|.*/core/|../core/|; s|.*/chat/|../chat/|; s|.*/frontend/|../frontend/|; s|.*/docs/|docs/|')
              echo -e "${CYAN}[$timestamp]${NC} ${DIM}Read${NC} $short"
            fi
            ;;
          Glob|Grep)
            pattern=$(echo "$line" | grep -o '"pattern":"[^"]*"' | head -1 | cut -d'"' -f4)
            echo -e "${CYAN}[$timestamp]${NC} ${DIM}$tool${NC} $pattern"
            ;;
          Skill)
            skill=$(echo "$line" | grep -o '"skill":"[^"]*"' | head -1 | cut -d'"' -f4)
            echo -e "${CYAN}[$timestamp]${NC} ${GREEN}Skill${NC} /$skill"
            ;;
          *)
            echo -e "${CYAN}[$timestamp]${NC} ${DIM}$tool${NC}"
            ;;
        esac
      fi
      ;;
    result)
      if echo "$line" | grep -q 'Tests.*passed\|tests pass\|PASS\| passed'; then
        match=$(echo "$line" | grep -o '[0-9]* passed\|[0-9]*/[0-9]* test' | head -1)
        [ -n "$match" ] && echo -e "${CYAN}[$timestamp]${NC} ${GREEN}Tests${NC} $match"
      fi
      if echo "$line" | grep -q 'FAIL\|Error\|error'; then
        echo -e "${CYAN}[$timestamp]${NC} ${RED}Error detected -- fixing...${NC}"
      fi
      if echo "$line" | grep -q 'coverage\|Coverage'; then
        cov=$(echo "$line" | grep -o '[0-9]*\.[0-9]*%' | head -1)
        [ -n "$cov" ] && echo -e "${CYAN}[$timestamp]${NC} ${GREEN}Coverage${NC} $cov"
      fi
      if echo "$line" | grep -q 'git commit\|committed'; then
        echo -e "${CYAN}[$timestamp]${NC} ${GREEN}Committed!${NC}"
      fi
      ;;
  esac
done

# ── Write usage summary ──
# Per-model rate card, selected from the model the stream actually reported.
# This used to hardcode Opus rates, which was wrong twice over: it priced
# Sonnet runs as Opus, AND the numbers were the retired $15/$75 Opus 3/4 card
# rather than current Opus 5. A Sonnet iteration came out ~6x too expensive,
# and RALPH_MAX_BUDGET_CENTS inherited the same error -- aborting runs early
# against spend that never happened.
#
# Rates are hundredths of a cent per 1M tokens (so $15.00/M -> 1500).
# cache_read = 0.1x input, cache_create (5m TTL) = 1.25x input.
case "${model_id:-}" in
  *fable*)      r_in=1000; r_out=5000; r_cr=100;  r_cc=1250; price_label="Fable 5" ;;
  *opus*)       r_in=500;  r_out=2500; r_cr=50;   r_cc=625;  price_label="Opus 5" ;;
  *sonnet-4-6*) r_in=300;  r_out=1500; r_cr=30;   r_cc=375;  price_label="Sonnet 4.6" ;;
  *sonnet*)     r_in=200;  r_out=1000; r_cr=20;   r_cc=250;  price_label="Sonnet 5" ;;
  *haiku*)      r_in=100;  r_out=500;  r_cr=10;   r_cc=125;  price_label="Haiku 4.5" ;;
  # Unknown/absent model: fall back to the most expensive current card so a
  # budget cap errs toward stopping early rather than overspending silently.
  *)            r_in=1000; r_out=5000; r_cr=100;  r_cc=1250; price_label="unknown model, Fable 5 rates" ;;
esac

# Calculate cost in cents to avoid floating point in bash
cost_input=$(( total_input * r_in / 1000000 ))
cost_output=$(( total_output * r_out / 1000000 ))
cost_cache_read=$(( total_cache_read * r_cr / 1000000 ))
cost_cache_create=$(( total_cache_create * r_cc / 1000000 ))
cost_total=$(( cost_input + cost_output + cost_cache_read + cost_cache_create ))

cat > "$USAGE_FILE" << EOJSON
{
  "input_tokens": $total_input,
  "output_tokens": $total_output,
  "cache_read_input_tokens": $total_cache_read,
  "cache_creation_input_tokens": $total_cache_create,
  "model": "${model_id:-unknown}",
  "cost_cents": $cost_total,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON

# Print cost summary to terminal
printf "\n"
printf "${BOLD}  Tokens:${NC}  input %sK | output %sK | cache_read %sM | cache_create %sK\n" \
  "$(( total_input / 1000 ))" \
  "$(( total_output / 1000 ))" \
  "$(( total_cache_read / 1000000 ))" \
  "$(( total_cache_create / 1000 ))"
printf "${BOLD}  Cost:${NC}    \$%d.%02d (%s API pricing)\n" \
  "$(( cost_total / 100 ))" \
  "$(( cost_total % 100 ))" \
  "$price_label"
