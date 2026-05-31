#!/usr/bin/env bash
set -uo pipefail
# Note: -e disabled intentionally -- individual failures are handled inline.

# ralph.sh - Ralph loop for F13 Shell Configurator (configurator_v1)
#
# Usage:
#   ./ralph.sh                          # defaults: PRD.md, 30 iterations, docker
#   ./ralph.sh PRD.md 20                # custom PRD and iteration count
#   ./ralph.sh PRD.md 30 local          # run locally (no Docker sandbox)
#   ./ralph.sh --tmux                   # launch in tmux split (live feed + dashboard)
#   ./ralph.sh --tmux PRD.md 20 docker  # tmux with custom args

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="configurator_v1"
PROGRESS="PROGRESS.md"
LOGDIR="ralph-logs"
STORIES_TOTAL=45  # S00..S31 GUI + S32, S34 (7.5) + S37..S40 (Phase 8) + S41..S47 (Phase 9). HF1–HF3 are hand-fixes outside this count.

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Tmux mode detection ──
TMUX_MODE=false
if [ "${1:-}" = "--tmux" ]; then
  TMUX_MODE=true
  shift
fi

PRD="${1:-PRD.md}"
MAX_ITERATIONS="${2:-30}"
MODE="${3:-docker}"
ITERATION=0

# ── Tmux launcher ──
if [ "$TMUX_MODE" = true ]; then
  command -v tmux >/dev/null 2>&1 || { echo -e "${RED}ERR: tmux not found. Install: brew install tmux${NC}"; exit 1; }

  SESSION="ralph-configurator"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -c "$SCRIPT_DIR" \
    "$SCRIPT_DIR/ralph.sh" "$PRD" "$MAX_ITERATIONS" "$MODE"
  tmux split-window -v -t "$SESSION" -c "$SCRIPT_DIR" -p 35 \
    "$SCRIPT_DIR/ralph-dashboard.sh" "$WORKDIR" 1
  tmux select-pane -t "$SESSION:0.0"
  tmux attach -t "$SESSION"
  exit 0
fi

# ── Load local env (webhook, etc.) — never committed ──
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/.env.local" ] && source "$SCRIPT_DIR/.env.local"

# ── Sanity checks ──
[ -f "$PRD" ] || { echo -e "${RED}ERR: $PRD not found.${NC}"; exit 1; }

# ── Create working directory and init git repo ──
mkdir -p "$WORKDIR"
if ! git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init "$WORKDIR"
  echo -e "${GREEN}Initialized git repo in $WORKDIR/${NC}"
fi

# ── Ensure LOOP_CONTEXT.md exists in working directory ──
#
# Note: the configurator's CLAUDE.md (tracked, thin pointer to
# AGENTS.md) is the entry point Claude Code auto-loads. This file
# carries the per-iteration loop state — current story, scope
# fences, backpressure reminders — that CLAUDE.md and AGENTS.md
# reference but don't include themselves.
if [ ! -f "$WORKDIR/LOOP_CONTEXT.md" ]; then
  cat > "$WORKDIR/LOOP_CONTEXT.md" << 'CLAUDEMD'
# F13 Shell Configurator -- Claude Code Instructions

Read /PRD.md for all rules. Key points:

## Mandatory Rules
- Language: Bash 4+. No Python, Node, or Go.
- Every executed script starts with `set -euo pipefail`.
- Functions are namespaced: `ui::`, `prompt::`, `secret::`, `ports::`, etc.
- Backpressure: shellcheck -S warning bin/* lib/*.sh && bats tests/
- Every new .sh file ships with at least one bats test.
- F13 commit convention: <TYPE> [scope]: <description> (max 72 chars)
  Types: ADD, RM, BF, NF, DOC, RF
- Every commit MUST end with: Co-Authored-By: Claude Code
- Update PROGRESS.md after every commit (see PRD for format).
- Never modify files in ../core, ../chat, ../frontend -- read-only references.
- Build everything in the current directory (/app inside Docker). Do NOT
  create a subdirectory for the project.
- Keycloak: guest mode on core (authentication.guest_mode: true) and
  KEYCLOAK_DISABLED=true on frontend. No Keycloak container is spun up.
- Host Ollama: chat container reaches it at host.docker.internal:11434
  (requires `extra_hosts` on Linux; see PRD S07 / S09).

## Git remote
- Remote: https://github.com/revolutionaryPhoton/f13-configurator.git (origin/main)
- Author/committer identity: David Moch <david.moch@gmail.com>
- DO NOT `git push` from inside the loop. The user pushes manually
  after reviewing each iteration. Just commit locally.
- The loop runs in a sandboxed docker container without GitHub
  credentials, so push attempts would fail anyway.

## Story tracks
- S00–S15: shell wizard core (Phase 0–5, complete, shipped v0.1.0).
- S16: patched frontend image with feature gating (Phase 6, complete, v0.1.0).
- S17–S31: desktop GUI (Phase 7, complete, shipped v0.2.0).
- S32 + S34: Phase 7.5 polish (complete, shipped v0.2.2).
- S37–S40: Phase 8 Linux runtime parity (complete, shipped v0.3.0).
- S41–S44: Phase 9 GUI i18n + zoom (complete, shipped v0.4.0 — loop-driven).
- HF1 / HF2 / HF3 / HF4: maintainer hand-fixes (v0.2.2 / v0.3.2 / v0.3.2 / v0.3.1).

### Current loop target: Phase 10 loop-runnable subset → v0.5.0

Active stories: **S51 + S52** — see PROGRESS.md "Pending Stories
— Phase 10". S51 lands first (Rust path resolution for bundled
installs); S52 builds on it (shell-script discovery).

Stories S53–S56 ship in the same Phase 10 PR but are maintainer-
driven (Apple cert + GitHub release secrets). Do NOT attempt them.
Drafting release.yml YAML skeleton is OK; wiring secrets is not.

Feature branch: feat/phase10-distributables. Single Phase 10 PR
rolls everything up at the end.

### Out of scope for this loop — do NOT pick from these

- S53/S54/S55/S56 (signing / .dmg / .AppImage+.deb / release CI
  secrets) — see above.
- HF5 in /PRD.md → promoted to S61 in Phase 11. Don't pick up
  until Phase 10 ships.
- Phase 11 / S61, S62 — targeted v0.6.0.
- Phase 12 / S71–S73 (Homebrew) — targeted v0.7.0.
- Phases 13–16 / S81–S115 — long-horizon, not active.

### When the loop IS active again (for future Phase reference)

Stack: Tauri 2.x + Svelte 5 + Vite + Tailwind 4 + TypeScript strict.
Backpressure (HEADLESS):
    cd gui && npm run check && npm run test:unit && cargo check
Plus shellcheck + bats for any non-gui changes.

Invoke /frontend-design-v2 skill before any .svelte UI file.
Coverage on TS/Svelte: >= 75%.

Multi-story phases land on a single feature branch (feat/phaseN-...)
with ONE PR at the end. Do NOT open per-story PRs.

  🚫 NEVER run `npm run tauri dev`, `tauri dev`, `cargo run`,
  `npm run tauri build`, or any Tauri WebDriver E2E inside the loop.
  The loop is headless; those commands hang waiting for a window.
CLAUDEMD
  echo -e "${GREEN}Created $WORKDIR/LOOP_CONTEXT.md${NC}"
fi

if [ "$MODE" = "docker" ]; then
  command -v docker >/dev/null 2>&1 || { echo -e "${RED}ERR: Docker not found.${NC}"; exit 1; }
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo -e "${RED}ERR: CLAUDE_CODE_OAUTH_TOKEN not set.${NC}"; exit 1; }
else
  command -v claude >/dev/null 2>&1 || { echo -e "${RED}ERR: claude not found. Install: npm i -g @anthropic-ai/claude-code${NC}"; exit 1; }
fi

# Initialize progress file and log directory
[ -f "$WORKDIR/$PROGRESS" ] || echo "# F13 Shell Configurator -- Progress" > "$WORKDIR/$PROGRESS"
mkdir -p "$WORKDIR/$LOGDIR"

PROMPT='You are operating inside a Ralph loop (iteration ITER_NUM of MAX_ITER).

Your working directory is the current directory - ALL new code goes here.
The shipped F13 services at "../core/", "../chat/", "../frontend/" are
READ-ONLY references (their YAML is the source of truth for templates).

Read /PRD.md for the full list of requirements and mandatory rules.
Read PROGRESS.md for what has already been completed.
Check git log --oneline -10 for recent work context.

RULES:
- Pick the SINGLE most important incomplete story from the PRD.
- Implement it fully (code, tests, docs as needed).
- Language is Bash 4+. No Python, Node, or Go.
- Every executed script starts with: set -euo pipefail
- Functions are namespaced (ui::, prompt::, secret::, ports::, etc.).
- User-facing output goes through lib/ui.sh helpers.
- Backpressure depends on which track the story is on:
  - Shell stories (anything OUTSIDE gui/):
        shellcheck -S warning bin/* lib/*.sh && bats tests/
  - GUI stories (anything INSIDE gui/, S17 onward):
        cd gui && npm run check && npm run test:unit && cargo check
    Plus the shell backpressure if the story also touched non-gui files.
  Both MUST pass before committing.
- 🚫 NEVER run any of: `npm run tauri dev`, `tauri dev`, `cargo run`,
  `npm run tauri build`, Tauri WebDriver E2E. The loop runs in a
  headless Linux Docker container with no display — those commands
  hang forever waiting for a window. Only headless backpressure
  (cargo check, vitest, biome, svelte-check) is allowed.
- 🍎 GUI validation target is macOS only. The loop only exercises
  the Linux *compile* path because that is where it runs. Do not
  add Linux-runtime tests, Linux distribution targets, or Linux
  bundle outputs to any story before Phase 8.
- Every new .sh file ships with at least one bats test.
- Every new .svelte/.ts file ships with at least one vitest test.
- Invoke /frontend-design-v2 skill before writing any .svelte UI file.
- Only commit if ALL checks pass.
- Commit message: <TYPE> [scope]: <description> (max 72 chars)
  Types: ADD, RM, BF, NF, DOC, RF
  Every commit body MUST end with: Co-Authored-By: Claude Code
- Update PROGRESS.md with detailed status after each commit (see PRD for format).
- After each commit, check if README.md needs updating. If yes, update
  it in the same commit.
- Never modify files in ../core, ../chat, ../frontend.
- Git remote: https://github.com/revolutionaryPhoton/f13-configurator.git
  (origin/main). DO NOT git push — the user pushes manually after review.
  Just commit locally.
- If ALL stories in the PRD are complete (none left in Pending Stories table of PROGRESS.md),
  you MUST output this exact string on its own line: <promise>COMPLETE</promise>
- If stories remain, summarize what you did and what is next.

DO NOT work on more than one story per iteration.
DO NOT skip backpressure checks.
DO NOT modify files outside the working directory.
If stuck after 3 attempts on the same issue, document the blocker and move on.'

PROMPT="${PROMPT//MAX_ITER/$MAX_ITERATIONS}"

# ── Opus pricing per 1M tokens (in cents) ──
P_IN=1500; P_OUT=7500; P_CR=150; P_CC=375

# ── Discord notifications ──
# Set RALPH_DISCORD_WEBHOOK env var to enable. If unset, notifications are silently skipped.
discord_notify() {
  [ -z "${RALPH_DISCORD_WEBHOOK:-}" ] && return
  local payload="$1"
  curl -s -X POST "$RALPH_DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || true
}

discord_iteration() {
  [ -z "${RALPH_DISCORD_WEBHOOK:-}" ] && return

  local new_commits iter_cost_str duration_str story_name
  new_commits=$(git -C "$WORKDIR" log --oneline "$commit_before..HEAD" 2>/dev/null | head -3 || true)
  story_name=$(echo "$new_commits" | head -1 | sed 's/^[a-f0-9]* //')

  local end_time; end_time=$(date +%s)
  local dur=$(( end_time - start_time ))
  duration_str="$(( dur / 60 ))m $(( dur % 60 ))s"

  iter_cost_str="n/a"
  if [ -f "$usagefile" ]; then
    local ic
    ic=$(grep -o '"cost_cents": *[0-9]*' "$usagefile" 2>/dev/null | grep -o '[0-9]*' || true)
    [ -n "$ic" ] && iter_cost_str="$(fmt_cost $ic)"
  fi

  local s_done s_pending
  s_done="$( (grep '^| S[0-9]' "$WORKDIR/$PROGRESS" 2>/dev/null || true) | wc -l | tr -d ' ')"
  s_pending=$(( STORIES_TOTAL - s_done ))
  [ "$s_pending" -lt 0 ] && s_pending=0

  local color=3447003  # blue

  discord_notify "$(cat <<EOJSON
{
  "embeds": [{
    "title": "Iteration $ITERATION complete",
    "description": "$(echo "$story_name" | sed 's/"/\\"/g')",
    "color": $color,
    "fields": [
      {"name": "Progress", "value": "${s_done}/${STORIES_TOTAL} stories", "inline": true},
      {"name": "Duration", "value": "$duration_str", "inline": true},
      {"name": "Cost", "value": "$iter_cost_str", "inline": true}
    ],
    "footer": {"text": "Ralph Loop - $WORKDIR"}
  }]
}
EOJSON
)"
}

discord_complete() {
  [ -z "${RALPH_DISCORD_WEBHOOK:-}" ] && return

  local t_cost=0 t_iterations=0
  for uf in "$WORKDIR/$LOGDIR"/usage-*.json; do
    [ -f "$uf" ] || continue
    t_iterations=$(( t_iterations + 1 ))
    local c
    c=$(grep -o '"cost_cents": *[0-9]*' "$uf" 2>/dev/null | grep -o '[0-9]*' || true)
    [ -n "$c" ] && t_cost=$(( t_cost + c ))
  done

  local s_done commits src_f test_f
  s_done="$( (grep '^| S[0-9]' "$WORKDIR/$PROGRESS" || true) | wc -l | tr -d ' ')"
  commits=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
  src_f=$(find "$WORKDIR/bin" "$WORKDIR/lib" -type f -name "*.sh" -o -type f -perm -u+x 2>/dev/null | wc -l | tr -d ' ')
  test_f=$(find "$WORKDIR/tests" -type f -name "*.bats" 2>/dev/null | wc -l | tr -d ' ')

  local color=5763719  # green

  discord_notify "$(cat <<EOJSON
{
  "content": "🏁 **Ralph Loop Complete!**",
  "embeds": [{
    "title": "All stories finished - $WORKDIR",
    "color": $color,
    "fields": [
      {"name": "Stories", "value": "${s_done} done", "inline": true},
      {"name": "Commits", "value": "$commits", "inline": true},
      {"name": "Iterations", "value": "$t_iterations", "inline": true},
      {"name": "Shell scripts", "value": "$src_f", "inline": true},
      {"name": "Bats tests", "value": "$test_f", "inline": true},
      {"name": "Total cost", "value": "$(fmt_cost $t_cost)", "inline": true}
    ],
    "footer": {"text": "cd $WORKDIR && ./bin/f13-config"}
  }]
}
EOJSON
)"

  osascript -e "display notification \"All ${s_done} stories done! Cost: $(fmt_cost $t_cost)\" with title \"Ralph Loop Complete\" sound name \"Glass\"" 2>/dev/null || true
}

# ── Helper functions ──
fmt_cost() { printf "\$%d.%02d" "$(( $1 / 100 ))" "$(( $1 % 100 ))"; }

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

run_claude_local() {
  local iter_prompt="${PROMPT//ITER_NUM/$1}"
  (cd "$WORKDIR" && claude --dangerously-skip-permissions --verbose --output-format stream-json -p "$iter_prompt")
}

run_claude_docker() {
  local iter_prompt="${PROMPT//ITER_NUM/$1}"
  local prompt_file
  prompt_file="$(mktemp)"
  printf '%s' "$iter_prompt" > "$prompt_file"
  local host_uid host_gid
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  local workdir_name="$WORKDIR"

  docker run --rm \
    -v "$(pwd):/workspace" \
    -v "$HOME/.claude:/home/node/.claude" \
    -v "$prompt_file:/tmp/prompt.txt:ro" \
    -w "/workspace/${workdir_name}" \
    -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}" \
    -e HOST_UID="$host_uid" \
    -e HOST_GID="$host_gid" \
    -e RALPH_WORKDIR="${workdir_name}" \
    --network host \
    node:24-bookworm-slim \
    bash -c '
      apt-get update -qq && apt-get install -y -qq \
        git shellcheck bats gettext-base \
        libwebkit2gtk-4.1-dev libglib2.0-dev libgtk-3-dev libssl-dev \
        build-essential librsvg2-dev patchelf libsoup-3.0-dev \
        libjavascriptcoregtk-4.1-dev curl wget >/dev/null 2>&1
      # Install Rust stable for cargo check (required by S17+ GUI stories)
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
        --default-toolchain stable -y --no-modify-path >/dev/null 2>&1 || true
      npm install -g @anthropic-ai/claude-code >/dev/null 2>&1

      RALPH_USER=node
      RALPH_HOME=/home/node
      if [ "$HOST_UID" != "$(id -u node)" ]; then
        groupadd -g "$HOST_GID" ralph 2>/dev/null || true
        useradd -u "$HOST_UID" -g "$HOST_GID" -d /home/ralph -s /bin/bash ralph 2>/dev/null || true
        mkdir -p /home/ralph
        cp -r /home/node/.claude /home/ralph/.claude 2>/dev/null || true
        chown -R "$HOST_UID:$HOST_GID" /home/ralph 2>/dev/null || true
        RALPH_USER=ralph
        RALPH_HOME=/home/ralph
      fi

      su "$RALPH_USER" -c "git config --global init.defaultBranch main"
      su "$RALPH_USER" -c "git config --global user.email \"david.moch@gmail.com\""
      su "$RALPH_USER" -c "git config --global user.name \"David Moch\""
      su "$RALPH_USER" -c "git config --global --add safe.directory /workspace"
      su "$RALPH_USER" -c "git config --global --add safe.directory /workspace/$RALPH_WORKDIR"

      cp /workspace/PRD.md /PRD.md 2>/dev/null || true
      chmod 644 /PRD.md

      export HOME="$RALPH_HOME"
      # Make Rust available (installed above as root, link to user home)
      if [ -d /root/.cargo/bin ]; then
        mkdir -p "$RALPH_HOME/.cargo/bin"
        cp -r /root/.cargo/bin/* "$RALPH_HOME/.cargo/bin/" 2>/dev/null || true
        cp -r /root/.cargo/env "$RALPH_HOME/.cargo/env" 2>/dev/null || true
        cp -r /root/.rustup "$RALPH_HOME/.rustup" 2>/dev/null || true
        chown -R "$HOST_UID:$HOST_GID" "$RALPH_HOME/.cargo" "$RALPH_HOME/.rustup" 2>/dev/null || true
      fi
      cat /tmp/prompt.txt | su "$RALPH_USER" -c "PATH=\$HOME/.cargo/bin:\$PATH stdbuf -oL claude --dangerously-skip-permissions --verbose --output-format stream-json -p"
    '
  rm -f "$prompt_file"
}

patch_progress_cost() {
  [ -f "$usagefile" ] || return
  local cost_cents input output cache_read
  cost_cents=$(grep -o '"cost_cents": *[0-9]*' "$usagefile" | grep -o '[0-9]*')
  input=$(grep -o '"input_tokens": *[0-9]*' "$usagefile" | grep -o '[0-9]*')
  output=$(grep -o '"output_tokens": *[0-9]*' "$usagefile" | grep -o '[0-9]*')
  cache_read=$(grep -o '"cache_read_input_tokens": *[0-9]*' "$usagefile" | grep -o '[0-9]*')
  [ -z "$cost_cents" ] && return

  local cost_str input_k output_k cache_m
  cost_str=$(printf "\$%d.%02d" "$(( cost_cents / 100 ))" "$(( cost_cents % 100 ))")
  input_k=$(( ${input:-0} / 1000 ))
  output_k=$(( ${output:-0} / 1000 ))
  cache_m=$(( ${cache_read:-0} / 1000000 ))

  local cost_line="- **API Cost (Opus):** ${cost_str} (input: ${input_k}K, output: ${output_k}K, cache: ${cache_m}M)"

  if grep -q '^\- \*\*Notes:\*\*' "$WORKDIR/$PROGRESS" 2>/dev/null; then
    local last_notes_line
    last_notes_line=$(grep -n '^\- \*\*Notes:\*\*' "$WORKDIR/$PROGRESS" | tail -1 | cut -d: -f1)
    if [ -n "$last_notes_line" ]; then
      local next_line=$(( last_notes_line + 1 ))
      if ! sed -n "${next_line}p" "$WORKDIR/$PROGRESS" | grep -q 'API Cost'; then
        sed -i.bak "${last_notes_line}a\\
${cost_line}" "$WORKDIR/$PROGRESS"
        rm -f "$WORKDIR/$PROGRESS.bak"
      fi
    fi
  fi
}

# ── Inline dashboard ──
show_dashboard() {
  local W=63

  _row()  { printf "${CYAN}║${NC}%-${W}s${CYAN}║${NC}\n" " $1"; }
  _rowb() { printf "${CYAN}║${NC}${BOLD}%-${W}s${NC}${CYAN}║${NC}\n" " $1"; }
  _sep()  { printf "${CYAN}╠"; printf '═%.0s' $(seq 1 $W); printf "╣${NC}\n"; }
  _top()  { printf "${CYAN}╔"; printf '═%.0s' $(seq 1 $W); printf "╗${NC}\n"; }
  _bot()  { printf "${CYAN}╚"; printf '═%.0s' $(seq 1 $W); printf "╝${NC}\n"; }

  local t_in=0 t_out=0 t_cr=0 t_cc=0 t_cost=0 i_count=0
  for uf in "$WORKDIR/$LOGDIR"/usage-*.json; do
    [ -f "$uf" ] || continue
    i_count=$(( i_count + 1 ))
    local v
    v=$(grep -o '"input_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*'); t_in=$(( t_in + ${v:-0} ))
    v=$(grep -o '"output_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*'); t_out=$(( t_out + ${v:-0} ))
    v=$(grep -o '"cache_read_input_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*'); t_cr=$(( t_cr + ${v:-0} ))
    v=$(grep -o '"cache_creation_input_tokens": *[0-9]*' "$uf" | grep -o '[0-9]*'); t_cc=$(( t_cc + ${v:-0} ))
    v=$(grep -o '"cost_cents": *[0-9]*' "$uf" | grep -o '[0-9]*'); t_cost=$(( t_cost + ${v:-0} ))
  done

  local s_done s_pending commits src_f test_f
  s_done="$( (grep '^| S[0-9]' "$WORKDIR/$PROGRESS" 2>/dev/null || true) | wc -l | tr -d ' ')"
  s_pending=$(( STORIES_TOTAL - s_done )); [ "$s_pending" -lt 0 ] && s_pending=0
  commits=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
  src_f=$(find "$WORKDIR/bin" "$WORKDIR/lib" -type f -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
  test_f=$(find "$WORKDIR/tests" -type f -name "*.bats" 2>/dev/null | wc -l | tr -d ' ')

  local c_in=$(( t_in * P_IN / 1000000 ))
  local c_out=$(( t_out * P_OUT / 1000000 ))
  local c_cr=$(( t_cr * P_CR / 1000000 ))
  local c_cc=$(( t_cc * P_CC / 1000000 ))
  local avg_iter=0; [ "$i_count" -gt 0 ] && avg_iter=$(( t_cost / i_count ))
  local avg_story=0; [ "$s_done" -gt 0 ] && avg_story=$(( t_cost / s_done ))

  local iter_cost="" iter_dur=""
  if [ -f "$usagefile" ]; then
    local ic
    ic=$(grep -o '"cost_cents": *[0-9]*' "$usagefile" | grep -o '[0-9]*')
    [ -n "$ic" ] && iter_cost="$(fmt_cost $ic)"
  fi
  local end_time; end_time=$(date +%s)
  local dur=$(( end_time - start_time ))
  iter_dur="$(( dur / 60 ))m $(( dur % 60 ))s"

  local new_commits
  new_commits=$(git -C "$WORKDIR" log --oneline "$commit_before..HEAD" 2>/dev/null || true)

  echo ""
  _top
  _rowb "    Ralph Loop - Iteration $ITERATION Complete (configurator)"
  _sep
  _row ""
  if [ -n "$new_commits" ]; then
    while IFS= read -r line; do
      _row "  $(printf '%-57s' "$line")"
    done <<< "$new_commits"
  else
    _row "  No new commits this iteration."
  fi
  _row ""
  _row "$(printf 'Duration: %-10s  Cost: %-10s' "$iter_dur" "${iter_cost:-n/a}")"
  _row "$(printf 'Shell scripts: %-3d  Bats tests: %-3d' "${src_f:-0}" "${test_f:-0}")"
  _row ""
  _sep
  _rowb "  Progress & Cost (Opus API Pricing)"
  _sep
  _row ""
  _row "$(printf 'Stories:   %d / %d done    (%d pending)' "$s_done" "$STORIES_TOTAL" "$s_pending")"
  _row "$(printf 'Commits:   %d total       Iterations: %d tracked' "$commits" "$i_count")"
  _row ""
  _row "$(printf '%-24s %8s tokens   %s' 'Input (uncached):' "$(fmt_tokens $t_in)" "$(fmt_cost $c_in)")"
  _row "$(printf '%-24s %8s tokens   %s' 'Output:' "$(fmt_tokens $t_out)" "$(fmt_cost $c_out)")"
  _row "$(printf '%-24s %8s tokens   %s' 'Cache read:' "$(fmt_tokens $t_cr)" "$(fmt_cost $c_cr)")"
  _row "$(printf '%-24s %8s tokens   %s' 'Cache creation:' "$(fmt_tokens $t_cc)" "$(fmt_cost $c_cc)")"
  _row "                                    -------------"
  _rowb "$(printf '%-24s              %s' 'TOTAL COST:' "$(fmt_cost $t_cost)")"
  _row ""
  _row "$(printf 'Avg per iteration: %-10s  Avg per story: %s' "$(fmt_cost $avg_iter)" "$(fmt_cost $avg_story)")"
  _row ""
  _bot
  echo ""
}

# ── Banner ──
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN} Ralph Loop - F13 Shell Configurator${NC}"
echo -e "${CYAN} PRD:            $PRD${NC}"
echo -e "${CYAN} Working dir:    $WORKDIR/${NC}"
echo -e "${CYAN} Read-only refs: ../core ../chat ../frontend${NC}"
echo -e "${CYAN} Max iterations: $MAX_ITERATIONS${NC}"
echo -e "${CYAN} Mode:           $MODE${NC}"
echo -e "${CYAN} Discord:        ${RALPH_DISCORD_WEBHOOK:+enabled}${RALPH_DISCORD_WEBHOOK:-disabled}${NC}"
echo -e "${CYAN}============================================${NC}"

# ── Discord: starting notification ──
discord_notify "$(cat <<EOJSON
{
  "embeds": [{
    "title": "Ralph Loop starting",
    "description": "Working directory: \`$WORKDIR\`\nMax iterations: $MAX_ITERATIONS\nMode: $MODE",
    "color": 16776960,
    "footer": {"text": "Hang on..."}
  }]
}
EOJSON
)"

# ── Pre-flight: check if already complete ──
if grep -q '## Pending Stories' "$WORKDIR/$PROGRESS" 2>/dev/null; then
  pending_count="$( (grep '^| S[0-9]' "$WORKDIR/$PROGRESS" || true) | wc -l | tr -d ' ')"
  if [ "$pending_count" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} All stories already complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    stories_done="$( (grep '^| S[0-9]' "$WORKDIR/$PROGRESS" || true) | wc -l | tr -d ' ')"
    commits=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
    echo -e "  Stories done: ${stories_done:-0}"
    echo -e "  Commits:      $commits"
    echo ""
    git -C "$WORKDIR" log --oneline -10
    echo ""
    "$SCRIPT_DIR/ralph-dashboard.sh" "$WORKDIR" 0
    discord_complete
    exit 0
  fi
fi

# ── Main loop ──
while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  start_time=$(date +%s)
  commit_before=$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo "")

  echo ""
  echo -e "${YELLOW}==== Iteration $ITERATION / $MAX_ITERATIONS ====${NC}"
  echo -e "     Started: $(date '+%Y-%m-%d %H:%M:%S')"

  iter_num=$(printf '%03d' $ITERATION)
  logfile="$WORKDIR/$LOGDIR/iteration-${iter_num}.json"
  usagefile="$WORKDIR/$LOGDIR/usage-${iter_num}.json"
  LIVE_FILTER="$SCRIPT_DIR/ralph-live.sh"

  if [ "$MODE" = "docker" ]; then
    run_claude_docker "$ITERATION" 2>&1 | tee "$logfile" | USAGE_FILE="$usagefile" "$LIVE_FILTER"
  else
    run_claude_local "$ITERATION" 2>&1 | tee "$logfile" | USAGE_FILE="$usagefile" "$LIVE_FILTER"
  fi
  OUTPUT=$(cat "$logfile")

  patch_progress_cost
  show_dashboard
  discord_iteration

  is_complete=false
  if echo "$OUTPUT" | grep -q '<promise>COMPLETE</promise>'; then
    is_complete=true
  elif grep -q '## Pending Stories' "$WORKDIR/$PROGRESS" 2>/dev/null; then
    pending_count="$( (grep '^| S[0-9]' "$WORKDIR/$PROGRESS" || true) | wc -l | tr -d ' ')"
    [ "$pending_count" -eq 0 ] && is_complete=true
  fi

  if [ "$is_complete" = true ]; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} All stories complete after $ITERATION iterations!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    show_dashboard
    discord_complete
    git -C "$WORKDIR" log --oneline
    exit 0
  fi

  sleep 2
done

echo ""
echo -e "${YELLOW}Hit max iterations ($MAX_ITERATIONS). Check progress:${NC}"
echo "   cat $WORKDIR/$PROGRESS"
echo "   git -C $WORKDIR log --oneline -10"
echo "   ./ralph-dashboard.sh"
