# f13-configurator-ralph

[![CI](https://github.com/revolutionaryPhoton/f13-configurator-ralph/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/revolutionaryPhoton/f13-configurator-ralph/actions/workflows/ci.yml)
[![Configurator CI](https://github.com/revolutionaryPhoton/f13-configurator/actions/workflows/gui-build.yml/badge.svg?branch=main&label=configurator)](https://github.com/revolutionaryPhoton/f13-configurator/actions/workflows/gui-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Made with Claude Code](https://img.shields.io/badge/made_with-Claude_Code-d77757)](https://claude.com/claude-code)

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
| `ralph.sh` | Main loop. Reads `PRD.md`, runs Claude Code in Docker (or locally), captures per-iteration logs and usage, commits to the sibling configurator repo. |
| `ralph-dashboard.sh` | Live cost / progress dashboard (`tmux` split or one-shot). Reads `ralph-logs/*.json` and the configurator's `PROGRESS.md`. |
| `ralph-live.sh` | Stream-json → human filter. Pipes Claude's verbose output into a tidy live feed and writes a usage summary at the end. |
| `PRD.md` | The product requirements document for the configurator. Story list (`S00`…`S16`) drives one iteration each. |
| `.env.example` | Template for `.env.local` (Discord webhook URL). |

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
./ralph.sh PRD.md 30 local  # use host claude CLI instead of docker
./ralph.sh --tmux           # tmux split: live feed + dashboard
```

Each iteration:

1. Reads `PRD.md` + the configurator's `PROGRESS.md` to pick the next story.
2. Runs Claude in a Docker sandbox (no host filesystem access beyond the
   configurator repo and `~/.claude`).
3. Implements one story. Backpressure runs `shellcheck` + `bats` from the
   configurator's perspective.
4. Commits locally with the F13 convention (`<TYPE> [scope]: ...` +
   `Co-Authored-By: Claude Code`).
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
