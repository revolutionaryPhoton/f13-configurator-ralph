#!/usr/bin/env bash
set -uo pipefail
# Note: -e disabled intentionally -- individual failures are handled inline.

# ralph.sh - Ralph loop for F13 Shell Configurator (configurator_v1)
#
# Usage:
#   ./ralph.sh                          # defaults: PRD.md, 30 iterations, docker
#   ./ralph.sh PRD.md 20                # custom PRD and iteration count
#   ./ralph.sh PRD.md 30 local          # run locally (no Docker sandbox)
#   ./ralph.sh PRD.md 30 sbx            # Docker Sandboxes microVM (Desktop 4.58+)
#   ./ralph.sh --tmux                   # launch in tmux split (live feed + dashboard)
#   ./ralph.sh --tmux PRD.md 20 docker  # tmux with custom args
#   ./ralph.sh --build                  # (re)build the sandbox image and exit
#   ./ralph.sh --sbx-check              # smoke-test the Docker Sandboxes setup
#
# Env knobs (see .env.example): RALPH_MAX_BUDGET_CENTS, RALPH_MAX_TURNS,
# RALPH_PERMISSION_MODE, RALPH_IMAGE, RALPH_CLAUDE_CODE_VERSION,
# RALPH_FIREWALL, RALPH_NET_ALLOW_EXTRA, RALPH_WORKDIR, RALPH_SBX_NAME,
# RALPH_SBX_TEMPLATE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${RALPH_WORKDIR:-configurator_v1}"
PROGRESS="PROGRESS.md"
LOGDIR="ralph-logs"
STORIES_TOTAL_FALLBACK=44  # used only if PROGRESS.md has no story tables; live total = Completed + Pending rows (see count_stories)

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

# ── Build-only mode: (re)build the sandbox image and exit ──
BUILD_ONLY=false
if [ "${1:-}" = "--build" ]; then
  BUILD_ONLY=true
  shift
fi

# ── Sbx smoke-test mode: verify Docker Sandboxes setup and exit ──
SBX_CHECK=false
if [ "${1:-}" = "--sbx-check" ]; then
  SBX_CHECK=true
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

# Re-evaluate values that .env.local may set
WORKDIR="${RALPH_WORKDIR:-$WORKDIR}"
RALPH_IMAGE="${RALPH_IMAGE:-f13-ralph:latest}"

# ── Sanity checks ──
[ -f "$PRD" ] || { echo -e "${RED}ERR: $PRD not found.${NC}"; exit 1; }
case "$MODE" in
  docker|local|sbx) ;;
  *) echo -e "${RED}ERR: unknown mode '$MODE' (docker|local|sbx).${NC}"; exit 1 ;;
esac

# Absolute paths for container mounts
PRD_ABS="$(cd "$(dirname "$PRD")" && pwd)/$(basename "$PRD")"
case "$WORKDIR" in
  /*) WORKDIR_HOST="$WORKDIR" ;;
  *)  WORKDIR_HOST="$(pwd)/$WORKDIR" ;;
esac

# ── Create working directory and init git repo ──
mkdir -p "$WORKDIR"
# Check for the workdir's OWN .git — rev-parse --is-inside-work-tree would
# also succeed for a plain directory nested inside another repo (e.g. a
# smoke-test workdir inside this harness repo), silently skipping the init.
if [ ! -d "$WORKDIR/.git" ]; then
  git init "$WORKDIR"
  echo -e "${GREEN}Initialized git repo in $WORKDIR/${NC}"
fi

# ── Ensure LOOP_CONTEXT.md exists in working directory ──
#
# LOOP_CONTEXT.md carries the per-iteration loop state — current
# story, scope fences, backpressure reminders. The configurator's
# CLAUDE.md (tracked, thin pointer to AGENTS.md) is the entry point
# Claude Code auto-loads; both it and AGENTS.md reference
# LOOP_CONTEXT.md but don't include the loop state themselves.
if [ ! -f "$WORKDIR/LOOP_CONTEXT.md" ]; then
  cat > "$WORKDIR/LOOP_CONTEXT.md" << 'LOOPCTX'
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
- Build everything in the current directory (/workspace inside Docker). Do NOT
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
LOOPCTX
  echo -e "${GREEN}Created $WORKDIR/LOOP_CONTEXT.md${NC}"
fi

case "$MODE" in
  docker)
    command -v docker >/dev/null 2>&1 || { echo -e "${RED}ERR: Docker not found.${NC}"; exit 1; }
    # --build / --sbx-check need no token — they never invoke claude with a prompt.
    [ "$BUILD_ONLY" = true ] || [ "$SBX_CHECK" = true ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo -e "${RED}ERR: CLAUDE_CODE_OAUTH_TOKEN not set.${NC}"; exit 1; }
    ;;
  sbx)
    command -v sbx >/dev/null 2>&1 || { echo -e "${RED}ERR: sbx CLI not found. Install: brew trust docker/tap && brew install docker/tap/sbx${NC}"; exit 1; }
    [ "$SBX_CHECK" = true ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo -e "${RED}ERR: CLAUDE_CODE_OAUTH_TOKEN not set.${NC}"; exit 1; }
    ;;
  local)
    command -v claude >/dev/null 2>&1 || { echo -e "${RED}ERR: claude not found. Install: npm i -g @anthropic-ai/claude-code${NC}"; exit 1; }
    ;;
esac

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

  local s_done s_total
  s_done=$(stories_done)
  s_total=$(stories_total)

  local color=3447003  # blue

  discord_notify "$(cat <<EOJSON
{
  "embeds": [{
    "title": "Iteration $ITERATION complete",
    "description": "$(echo "$story_name" | sed 's/"/\\"/g')",
    "color": $color,
    "fields": [
      {"name": "Progress", "value": "${s_done}/${s_total} stories", "inline": true},
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

  local t_cost t_iterations=0
  t_cost=$(total_cost_cents)
  for uf in "$WORKDIR/$LOGDIR"/usage-*.json; do
    [ -f "$uf" ] || continue
    t_iterations=$(( t_iterations + 1 ))
  done

  local s_done commits src_f test_f
  s_done=$(stories_done)
  commits=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
  src_f=$(find "$WORKDIR/bin" "$WORKDIR/lib" -type f \( -name "*.sh" -o -perm -u+x \) 2>/dev/null | wc -l | tr -d ' ')
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

# Count "| Sxx |" story rows inside one "## <section>" of PROGRESS.md.
#   $1 = section heading prefix, e.g. "Completed Stories" / "Pending Stories"
#   $2 = filter: all | done | open  ("done" = Status cell contains **done**)
# NOTE: keep in sync with the copy in ralph-dashboard.sh.
count_stories() {
  awk -v sec="## $1" -v mode="${2:-all}" '
    index($0, sec) == 1 { insec = 1; next }
    /^## /              { insec = 0 }
    insec && /^\| S[0-9]/ {
      isdone = ($0 ~ /\*\*done\*\*/)
      if (mode == "all" || (mode == "done" && isdone) || (mode == "open" && !isdone)) n++
    }
    END { print n + 0 }
  ' "$WORKDIR/$PROGRESS" 2>/dev/null || echo 0
}

# Done = Completed table + Pending rows already marked **done**.
stories_done() {
  echo $(( $(count_stories "Completed Stories" all) + $(count_stories "Pending Stories" "done") ))
}

# Total = every story row listed, any status; fallback if tables absent.
stories_total() {
  local t
  t=$(( $(count_stories "Completed Stories" all) + $(count_stories "Pending Stories" all) ))
  if [ "$t" -gt 0 ]; then echo "$t"; else echo "$STORIES_TOTAL_FALLBACK"; fi
}

# Per-invocation claude flags shared by all modes. Defaults reproduce the
# historical behavior plus a --max-turns runaway guard.
#   RALPH_MAX_TURNS        per-iteration turn cap (default 200; 0 = unlimited)
#   RALPH_PERMISSION_MODE  bypass (default, --dangerously-skip-permissions;
#                          safe only inside the sandbox) or a claude
#                          --permission-mode value such as acceptEdits
CLAUDE_FLAGS=()
build_claude_flags() {
  CLAUDE_FLAGS=(--verbose --output-format stream-json)
  local turns="${RALPH_MAX_TURNS:-200}"
  if [ "$turns" != "0" ]; then
    CLAUDE_FLAGS+=(--max-turns "$turns")
  fi
  case "${RALPH_PERMISSION_MODE:-bypass}" in
    bypass) CLAUDE_FLAGS+=(--dangerously-skip-permissions) ;;
    *)      CLAUDE_FLAGS+=(--permission-mode "$RALPH_PERMISSION_MODE") ;;
  esac
  CLAUDE_FLAGS+=(-p)
}

# Cumulative cost in cents across every usage-*.json in the log dir
# (lifetime of the log dir, i.e. across runs).
total_cost_cents() {
  local t=0 c uf
  for uf in "$WORKDIR/$LOGDIR"/usage-*.json; do
    [ -f "$uf" ] || continue
    c=$(grep -o '"cost_cents": *[0-9]*' "$uf" 2>/dev/null | grep -o '[0-9]*' || true)
    [ -n "$c" ] && t=$(( t + c ))
  done
  echo "$t"
}

# Budget kill-switch: RALPH_MAX_BUDGET_CENTS > 0 caps cumulative spend.
# Returns 1 (abort the loop) once spent >= cap.
check_budget() {
  local cap="${RALPH_MAX_BUDGET_CENTS:-0}"
  case "$cap" in
    ''|0) return 0 ;;
    *[!0-9]*)
      # A malformed cap must abort, not silently mean "unlimited".
      echo -e "${RED}ERR: RALPH_MAX_BUDGET_CENTS must be a whole number of cents (got '$cap').${NC}"
      return 1 ;;
  esac
  local spent
  spent=$(total_cost_cents)
  [ "$spent" -lt "$cap" ] && return 0
  echo ""
  echo -e "${RED}============================================${NC}"
  echo -e "${RED} BUDGET CAP HIT: $(fmt_cost "$spent") spent >= cap $(fmt_cost "$cap")${NC}"
  echo -e "${RED} Aborting loop (RALPH_MAX_BUDGET_CENTS=$cap)${NC}"
  echo -e "${RED}============================================${NC}"
  discord_notify "$(cat <<EOJSON
{
  "embeds": [{
    "title": "Ralph Loop ABORTED — budget cap",
    "description": "Spent $(fmt_cost "$spent") of cap $(fmt_cost "$cap") (RALPH_MAX_BUDGET_CENTS=$cap)",
    "color": 15548997,
    "footer": {"text": "Ralph Loop - $WORKDIR"}
  }]
}
EOJSON
)"
  return 1
}

# Build the prebuilt sandbox image if missing, if its baked uid/gid no
# longer match the host (self-heals after moving between machines), or
# when forced via --build.
# Build context is docker/ only — the harness repo is never sent to the daemon.
ensure_docker_image() {
  if [ "${1:-}" != "--force" ] && docker image inspect "$RALPH_IMAGE" >/dev/null 2>&1; then
    local baked_uid baked_gid
    baked_uid=$(docker image inspect -f '{{index .Config.Labels "f13.ralph.uid"}}' "$RALPH_IMAGE" 2>/dev/null)
    baked_gid=$(docker image inspect -f '{{index .Config.Labels "f13.ralph.gid"}}' "$RALPH_IMAGE" 2>/dev/null)
    if [ "$baked_uid" = "$(id -u)" ] && [ "$baked_gid" = "$(id -g)" ]; then
      return 0
    fi
    echo -e "${YELLOW}Image $RALPH_IMAGE was built for uid/gid ${baked_uid:-?}/${baked_gid:-?}, host is $(id -u)/$(id -g) — rebuilding.${NC}"
  fi
  echo -e "${CYAN}Building sandbox image $RALPH_IMAGE ...${NC}"
  docker build \
    --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
    ${RALPH_CLAUDE_CODE_VERSION:+--build-arg CLAUDE_CODE_VERSION="$RALPH_CLAUDE_CODE_VERSION"} \
    -t "$RALPH_IMAGE" \
    -f "$SCRIPT_DIR/docker/ralph.Dockerfile" "$SCRIPT_DIR/docker" \
    || { echo -e "${RED}ERR: docker build failed.${NC}"; return 1; }
}

# ── Docker Sandboxes (MODE=sbx): microVM isolation via the sbx CLI ──
# Install: brew trust docker/tap && brew install docker/tap/sbx
# (the old "docker sandbox" plugin was removed by Docker in 2026-06).
# One-time: sbx login (Docker sign-in).
# The sandbox is created once and reused (fast iterations, persistent
# cargo/npm caches); each `exec ... claude -p` is still a fresh
# conversation, so fresh-context-per-iteration is preserved.
# Reset with: sbx rm "$SBX_NAME"
SBX_NAME="${RALPH_SBX_NAME:-f13-ralph}"
SBX_TEMPLATE="${RALPH_SBX_TEMPLATE:-f13-ralph-sbx:latest}"
SBX_PRD_DIR="$SCRIPT_DIR/.ralph-sbx"  # gitignored one-file staging dir (ro in sandbox)
SBX_ALLOW_HOSTS="api.anthropic.com,registry.npmjs.org,crates.io,static.crates.io,index.crates.io"

ensure_sbx_sandbox() {
  # Auth first — everything below would otherwise fail with the same
  # error and mask the real cause.
  sbx ls >/dev/null 2>&1 \
    || { echo -e "${RED}ERR: sbx not authenticated. Run: sbx login${NC}"; return 1; }
  # sbx runs its own image store inside the VM — build on the host
  # daemon, then load the tar into the sandbox runtime when missing.
  if ! sbx template ls 2>/dev/null | awk '{print $1}' | grep -qx -e "${SBX_TEMPLATE%%:*}" -e "$SBX_TEMPLATE"; then
    if ! docker image inspect "$SBX_TEMPLATE" >/dev/null 2>&1; then
      echo -e "${CYAN}Building sbx template $SBX_TEMPLATE ...${NC}"
      docker build -t "$SBX_TEMPLATE" \
        -f "$SCRIPT_DIR/docker/sbx-template.Dockerfile" "$SCRIPT_DIR/docker" \
        || { echo -e "${RED}ERR: sbx template build failed.${NC}"; return 1; }
    fi
    echo -e "${CYAN}Loading template into the sandbox runtime ...${NC}"
    local tarf
    tarf="$(mktemp -u).tar"
    docker save -o "$tarf" "$SBX_TEMPLATE" \
      && sbx template load "$tarf" \
      || { rm -f "$tarf"; echo -e "${RED}ERR: sbx template load failed.${NC}"; return 1; }
    rm -f "$tarf"
  fi
  # Global network policy must be initialized before the first sandbox
  # start. Initializing it is a ONE-TIME, MACHINE-WIDE decision (applies
  # to all sbx sandboxes, not just this loop's), so the harness never
  # does it silently — the operator opts in via RALPH_SBX_POLICY_INIT.
  if ! sbx policy ls >/dev/null 2>&1; then
    if [ "${RALPH_SBX_POLICY_INIT:-}" = "deny-all" ]; then
      echo -e "${CYAN}Initializing global sbx network policy (deny-all, per RALPH_SBX_POLICY_INIT) ...${NC}"
      sbx policy init deny-all \
        || { echo -e "${RED}ERR: sbx policy init failed.${NC}"; return 1; }
    else
      echo -e "${RED}ERR: the global sbx network policy is not initialized.${NC}"
      echo -e "${RED}This is a one-time, machine-wide choice affecting ALL sbx sandboxes.${NC}"
      echo -e "${RED}Either run:  sbx policy init deny-all   (recommended for this loop)${NC}"
      echo -e "${RED}or set RALPH_SBX_POLICY_INIT=deny-all to let ralph.sh do it for you.${NC}"
      return 1
    fi
  fi
  # Sandboxes mount host paths verbatim — stage PRD.md in a dedicated
  # one-file dir so the harness repo itself is never exposed.
  mkdir -p "$SBX_PRD_DIR"
  cp "$PRD_ABS" "$SBX_PRD_DIR/PRD.md"
  if ! sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$SBX_NAME"; then
    echo -e "${CYAN}Creating sandbox $SBX_NAME (workspace: $WORKDIR_HOST) ...${NC}"
    sbx create -t "$SBX_TEMPLATE" --name "$SBX_NAME" -q claude \
      "$WORKDIR_HOST" "$SBX_PRD_DIR:ro" \
      || { echo -e "${RED}ERR: sbx create failed.${NC}"; return 1; }
    local allow="$SBX_ALLOW_HOSTS"
    local extra
    for extra in ${RALPH_NET_ALLOW_EXTRA:-}; do
      allow="$allow,$extra"
    done
    sbx policy allow network --sandbox "$SBX_NAME" "$allow" \
      || { echo -e "${RED}ERR: sbx allowlist failed.${NC}"; return 1; }
  fi
}

run_claude_sbx() {
  local iter_prompt="${PROMPT//ITER_NUM/$1}"
  # Workspaces mount at the host path, so /PRD.md does not exist in sbx
  # mode — point the prompt at the staged copy instead.
  iter_prompt="${iter_prompt///PRD.md/$SBX_PRD_DIR/PRD.md}"
  # Token via value-less -e pass-through: sbx reads the value from this
  # process's environment, so it never appears on argv. (--env-file is
  # silently ignored by sbx v0.34 — verified; do not use it.)
  # </dev/null skips sbx's 3s stdin wait: the prompt is passed as an arg.
  sbx exec -e CLAUDE_CODE_OAUTH_TOKEN \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -w "$WORKDIR_HOST" "$SBX_NAME" \
    stdbuf -oL claude "${CLAUDE_FLAGS[@]}" "$iter_prompt" < /dev/null
}

sbx_check() {
  echo -e "${CYAN}sbx check: sbx CLI ...${NC}"
  command -v sbx >/dev/null 2>&1 \
    || { echo -e "${RED}sbx CLI missing. Install: brew trust docker/tap && brew install docker/tap/sbx${NC}"; return 1; }
  sbx version || return 1
  sbx ls >/dev/null 2>&1 \
    || { echo -e "${RED}sbx not authenticated. Run: sbx login${NC}"; return 1; }
  ensure_sbx_sandbox || return 1
  echo -e "${CYAN}sbx check: claude + toolchain inside sandbox ...${NC}"
  sbx exec "$SBX_NAME" claude --version || return 1
  sbx exec "$SBX_NAME" bash -c \
    'shellcheck --version >/dev/null && bats --version >/dev/null && cargo --version >/dev/null && echo "toolchain OK"' \
    || return 1
  echo -e "${CYAN}sbx check: egress policy ...${NC}"
  # -f matters: the sandbox blocks by answering HTTP 403, which plain
  # curl -s would report as success.
  if sbx exec "$SBX_NAME" curl -sf -m 5 https://example.com >/dev/null 2>&1; then
    echo -e "${YELLOW}WARN: network policy not enforced (example.com reachable)${NC}"
  else
    echo -e "${GREEN}egress blocked outside allowlist${NC}"
  fi
  if sbx exec "$SBX_NAME" curl -s -m 10 -o /dev/null https://api.anthropic.com; then
    echo -e "${GREEN}api.anthropic.com reachable${NC}"
  else
    echo -e "${YELLOW}WARN: api.anthropic.com NOT reachable — check sbx policy${NC}"
  fi
  echo -e "${GREEN}sbx check OK${NC}"
}

run_claude_local() {
  local iter_prompt="${PROMPT//ITER_NUM/$1}"
  (cd "$WORKDIR" && claude "${CLAUDE_FLAGS[@]}" "$iter_prompt")
}

# Hardened sandbox run. The container sees ONLY the product repo (rw),
# PRD.md (ro) and the prompt (ro) — no harness repo, no .env.local, no
# ~/.claude. Auth is solely CLAUDE_CODE_OAUTH_TOKEN (value-less -e keeps
# the token off this script's argv). Egress is locked to an allowlist by
# the image entrypoint (NET_ADMIN/NET_RAW are needed only to raise the
# firewall; claude itself runs unprivileged after the setpriv drop).
run_claude_docker() {
  local iter_prompt="${PROMPT//ITER_NUM/$1}"
  local prompt_file
  prompt_file="$(mktemp)"
  printf '%s' "$iter_prompt" > "$prompt_file"

  docker run --rm --init \
    -v "$WORKDIR_HOST:/workspace" \
    -v "$PRD_ABS:/PRD.md:ro" \
    -v "$prompt_file:/prompt.txt:ro" \
    -w /workspace \
    -e CLAUDE_CODE_OAUTH_TOKEN \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -e RALPH_FIREWALL="${RALPH_FIREWALL:-on}" \
    -e RALPH_NET_ALLOW_EXTRA="${RALPH_NET_ALLOW_EXTRA:-}" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt no-new-privileges \
    "$RALPH_IMAGE" "${CLAUDE_FLAGS[@]}"

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

  local s_done s_total s_pending commits src_f test_f
  s_done=$(stories_done)
  s_total=$(stories_total)
  s_pending=$(count_stories "Pending Stories" open)
  commits=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
  src_f=$(find "$WORKDIR/bin" "$WORKDIR/lib" -type f \( -name "*.sh" -o -perm -u+x \) 2>/dev/null | wc -l | tr -d ' ')
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
  if [ -n "$commit_before" ]; then
    new_commits=$(git -C "$WORKDIR" log --oneline "$commit_before..HEAD" 2>/dev/null || true)
  else
    # Fresh repo: no HEAD existed before this iteration — everything is new.
    new_commits=$(git -C "$WORKDIR" log --oneline 2>/dev/null || true)
  fi

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
  _row "$(printf 'Stories:   %d / %d done    (%d pending)' "$s_done" "$s_total" "$s_pending")"
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

# ── Sandbox image (build-only / sbx-check modes exit here) ──
if [ "$BUILD_ONLY" = true ]; then
  ensure_docker_image --force
  exit $?
fi
if [ "$SBX_CHECK" = true ]; then
  sbx_check
  exit $?
fi
if [ "$MODE" = "docker" ]; then
  ensure_docker_image || exit 1
elif [ "$MODE" = "sbx" ]; then
  ensure_sbx_sandbox || exit 1
fi

# ── Banner ──
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN} Ralph Loop - F13 Shell Configurator${NC}"
echo -e "${CYAN} PRD:            $PRD${NC}"
echo -e "${CYAN} Working dir:    $WORKDIR/${NC}"
echo -e "${CYAN} Read-only refs: ../core ../chat ../frontend${NC}"
echo -e "${CYAN} Max iterations: $MAX_ITERATIONS${NC}"
echo -e "${CYAN} Mode:           $MODE${NC}"
if [ "$MODE" = "docker" ]; then
  echo -e "${CYAN} Image:          $RALPH_IMAGE${NC}"
  echo -e "${CYAN} Firewall:       ${RALPH_FIREWALL:-on}${NC}"
elif [ "$MODE" = "sbx" ]; then
  echo -e "${CYAN} Sandbox:        $SBX_NAME (template: $SBX_TEMPLATE)${NC}"
fi
budget_disp="unlimited"
[ "${RALPH_MAX_BUDGET_CENTS:-0}" -gt 0 ] 2>/dev/null && budget_disp="$(fmt_cost "$RALPH_MAX_BUDGET_CENTS")"
echo -e "${CYAN} Max turns:      ${RALPH_MAX_TURNS:-200}${NC}"
echo -e "${CYAN} Permissions:    ${RALPH_PERMISSION_MODE:-bypass}${NC}"
echo -e "${CYAN} Budget cap:     ${budget_disp}${NC}"
echo -e "${CYAN} Discord:        $([ -n "${RALPH_DISCORD_WEBHOOK:-}" ] && echo enabled || echo disabled)${NC}"
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
  pending_count=$(count_stories "Pending Stories" open)
  if [ "$pending_count" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} All stories already complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    done_count=$(stories_done)
    commits=$(git -C "$WORKDIR" rev-list --count HEAD 2>/dev/null || echo 0)
    echo -e "  Stories done: ${done_count:-0}"
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
build_claude_flags
check_budget || exit 2

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  check_budget || exit 2
  ITERATION=$((ITERATION + 1))
  start_time=$(date +%s)
  # -q --verify: plain "rev-parse HEAD" echoes the literal string "HEAD"
  # to stdout on an unborn branch, which would poison the ..HEAD range.
  commit_before=$(git -C "$WORKDIR" rev-parse -q --verify HEAD 2>/dev/null || true)

  echo ""
  echo -e "${YELLOW}==== Iteration $ITERATION / $MAX_ITERATIONS ====${NC}"
  echo -e "     Started: $(date '+%Y-%m-%d %H:%M:%S')"

  iter_num=$(printf '%03d' $ITERATION)
  logfile="$WORKDIR/$LOGDIR/iteration-${iter_num}.json"
  usagefile="$WORKDIR/$LOGDIR/usage-${iter_num}.json"
  LIVE_FILTER="$SCRIPT_DIR/ralph-live.sh"

  if [ "$MODE" = "docker" ]; then
    run_claude_docker "$ITERATION" 2>&1 | tee "$logfile" | USAGE_FILE="$usagefile" "$LIVE_FILTER"
  elif [ "$MODE" = "sbx" ]; then
    run_claude_sbx "$ITERATION" 2>&1 | tee "$logfile" | USAGE_FILE="$usagefile" "$LIVE_FILTER"
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
    pending_count=$(count_stories "Pending Stories" open)
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
