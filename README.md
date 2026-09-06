# f13-configurator-ralph

![GitHub stars](https://img.shields.io/github/stars/revolutionaryPhoton/f13-configurator-ralph?style=social)
![GitHub forks](https://img.shields.io/github/forks/revolutionaryPhoton/f13-configurator-ralph?style=social)
![GitHub watchers](https://img.shields.io/github/watchers/revolutionaryPhoton/f13-configurator-ralph?style=social)

[![CI](https://github.com/revolutionaryPhoton/f13-configurator-ralph/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/revolutionaryPhoton/f13-configurator-ralph/actions/workflows/ci.yml)
[![Configurator CI](https://github.com/revolutionaryPhoton/f13-configurator/actions/workflows/gui-build.yml/badge.svg?branch=main&label=configurator)](https://github.com/revolutionaryPhoton/f13-configurator/actions/workflows/gui-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![GitHub repo size](https://img.shields.io/github/repo-size/revolutionaryPhoton/f13-configurator-ralph)
![GitHub top language](https://img.shields.io/github/languages/top/revolutionaryPhoton/f13-configurator-ralph)
![GitHub last commit](https://img.shields.io/github/last-commit/revolutionaryPhoton/f13-configurator-ralph?color=red)
![GitHub open issues](https://img.shields.io/github/issues/revolutionaryPhoton/f13-configurator-ralph)
![GitHub open PRs](https://img.shields.io/github/issues-pr/revolutionaryPhoton/f13-configurator-ralph)

[![Bash](https://img.shields.io/badge/Bash-4%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Docker](https://img.shields.io/badge/Docker-required-2496ED?logo=docker&logoColor=white)](https://www.docker.com)
[![Claude Code](https://img.shields.io/badge/drives-Claude_Code-d77757)](https://claude.com/claude-code)
[![Anthropic API](https://img.shields.io/badge/API-Anthropic-191919?logo=anthropic&logoColor=white)](https://www.anthropic.com)

The Ralph-loop harness that drives Claude Code through the implementation of
the [F13 Configurator](https://github.com/revolutionaryPhoton/f13-configurator)
— a setup wizard for F13 deployments with both a shell and a desktop-GUI
surface. Each iteration: read a PRD, pick the next story, implement it, run
backpressure checks, commit, repeat.

> **Heads up — this is operator tooling, not a product.** It runs Claude Code
> with `--dangerously-skip-permissions` inside Docker, burns Anthropic API
> credits, and writes commits to a separate sibling repo. Read
> [SECURITY.md](SECURITY.md) before running it.

> ⚠️  **Both this repo and the configurator it drives are largely AI-generated.**
> The harness scripts here (`ralph.sh`, `ralph-dashboard.sh`, `ralph-live.sh`,
> `PRD.md`) were written mostly by Claude Code in interactive sessions on macOS
> and Linux. The configurator at
> [revolutionaryPhoton/f13-configurator](https://github.com/revolutionaryPhoton/f13-configurator)
> was produced inside this very automated loop. Anyone reading either codebase
> should treat the generated code as needing review before relying on it.

---

## What's in here

| File | Purpose |
|---|---|
| `ralph.sh` | Main loop. Reads `PRD.md`, runs Claude Code in a sandbox (see modes below), captures per-iteration logs and usage, commits to the sibling configurator repo. |
| `ralph-dashboard.sh` | Live cost / progress dashboard (`tmux` split or one-shot). Reads `ralph-logs/*.json` and the configurator's `PROGRESS.md`. |
| `ralph-live.sh` | Stream-json → human filter. Pipes Claude's verbose output into a tidy live feed and writes a usage summary at the end. |
| `docker/` | Sandbox pieces: `ralph.Dockerfile` (prebuilt pinned image), `init-firewall.sh` + `ralph-entrypoint.sh` (egress allowlist, privilege drop), `sbx-template.Dockerfile` (Docker Sandboxes template). |
| `smoke.sh` | Unattended generate + launch + report for the configurator stack. Always renders via `F13_STATE_ACTION=reset` (the interactive "keep" path can reuse a damaged `generated/`), pre-checks every bind-mount source, then reports container state and dumps logs for anything that did not survive. `SMOKE_BUILD=1` also rebuilds the patched frontend image. |
| `PRD.md` | The product requirements document for the configurator. Story list (`S00`…`S130`, grows per phase) drives one iteration each. |
| `.env.example` | Template for `.env.local` (Discord webhook + guardrail/sandbox knobs). |

## Sandbox modes

| Mode | Isolation | Notes |
|---|---|---|
| `docker` (default) | Hardened container: prebuilt pinned image, only the product repo + PRD (ro) mounted, no `~/.claude`, default-DROP egress allowlist, non-root agent | `./ralph.sh` — image auto-builds on first run (`./ralph.sh --build` to rebuild) |
| `sbx` | **Docker Sandboxes microVM** (*experimental*): hypervisor boundary, policy-enforced egress allowlist. Needs the `sbx` CLI (`brew trust docker/tap && brew install docker/tap/sbx`) + one-time `sbx login` | `./ralph.sh PRD.md 30 sbx` — smoke-test first with `./ralph.sh --sbx-check` |
| `local` | None (host CLI) | `./ralph.sh PRD.md 30 local` — for sanity checks only |

Guardrails in every mode: `--max-turns` per iteration (`RALPH_MAX_TURNS`,
default 200), a cumulative budget kill-switch (`RALPH_MAX_BUDGET_CENTS` —
the loop aborts before invoking Claude once spend reaches the cap), and a
configurable permission mode (`RALPH_PERMISSION_MODE`, default `bypass`).
See `.env.example` for all knobs and [SECURITY.md](SECURITY.md) for the
full posture.

## How it expects the disk to be laid out

```
parent-folder/
├── this-repo/                       ← f13-configurator-ralph (you are here)
│   ├── ralph.sh
│   ├── PRD.md
│   ├── .env.local                   (gitignored, you create this)
│   ├── OPERATIONS.md                (gitignored, optional personal runbook)
│   └── configurator_v1/             ← cloned separately, see below
│       └── ... (the configurator project)
```

`configurator_v1/` is the sibling project at
[github.com/revolutionaryPhoton/f13-configurator](https://github.com/revolutionaryPhoton/f13-configurator).
Clone it as a sub-directory of this repo (it is gitignored here):

```bash
git clone https://github.com/revolutionaryPhoton/f13-configurator-ralph.git
cd f13-configurator-ralph
git clone https://github.com/revolutionaryPhoton/f13-configurator.git configurator_v1
cp .env.example .env.local        # optional: paste a Discord webhook URL
```

## Running a loop

Prerequisites: Docker, a Claude Max / Pro / API account, and a long-lived
OAuth token from `claude setup-token`.

```bash
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
./ralph.sh                  # default: PRD.md, 30 iterations, docker mode
./ralph.sh PRD.md 1 docker  # one iteration sanity check
./ralph.sh PRD.md 30 sbx    # Docker Sandboxes microVM mode
./ralph.sh PRD.md 30 local  # use host claude CLI instead of docker
./ralph.sh --tmux           # tmux split: live feed + dashboard
./ralph.sh --build          # (re)build the sandbox image
./ralph.sh --sbx-check      # smoke-test the Docker Sandboxes setup
```

Each iteration:

1. Reads `PRD.md` + the configurator's `PROGRESS.md` to pick the next story.
2. Runs Claude in the sandbox (only the configurator repo rw + `PRD.md`
   ro are visible; egress locked to an allowlist; no `~/.claude`).
3. Implements one story. Backpressure runs `shellcheck` + `bats` from the
   configurator's perspective.
4. Commits locally with the F13 convention (`<TYPE> [scope]: ...` +
   `Co-Authored-By: Claude Code, <model>`).
5. Writes `ralph-logs/iteration-NNN.json` and `usage-NNN.json`.
6. Optionally pings Discord.

The loop stops when the model emits `<promise>COMPLETE</promise>` or all
PRD stories are checked off in the configurator's `PROGRESS.md`.

## Useful one-liners

```bash
# Live cost dashboard, refreshing every 5 minutes
./ralph-dashboard.sh configurator_v1 5

# One-shot dashboard render (no refresh)
./ralph-dashboard.sh configurator_v1 0

# What did the loop just do?
git -C configurator_v1 log --oneline -10
cat configurator_v1/PROGRESS.md
```

## Editing the PRD

The PRD is the only file the loop reads to decide what to do. Edit
`PRD.md` to add stories, change rules, or rescope. After editing, run a
single-iteration sanity check before kicking off a long run:

```bash
./ralph.sh PRD.md 1 docker
```

If a story spec is wrong (regex doesn't match, paths missing, etc.), the
loop tends to silently produce broken code. Always do a one-iteration
shake-out first.

## License

MIT — see [LICENSE](LICENSE).
