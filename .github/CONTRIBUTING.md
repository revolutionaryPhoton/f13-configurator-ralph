# Contributing to f13-configurator-ralph

This repo is the **harness** that drives Claude Code through the
implementation of the
[F13 Configurator](https://github.com/revolutionaryPhoton/f13-configurator).
It's operator tooling, not a product — three Bash scripts, a PRD,
and some docs. Contributions are welcome; here's what to know first.

## Read this first

The harness scripts (`ralph.sh`, `ralph-dashboard.sh`,
`ralph-live.sh`) and `PRD.md` were largely AI-generated (Claude Code
in interactive macOS / Linux sessions). The configurator they
produce was generated inside this very loop. Read
[`SECURITY.md`](../SECURITY.md) for the implications — most
importantly, the harness runs Claude Code with
`--dangerously-skip-permissions` inside Docker and burns Anthropic
API credits.

## Repo layout

- `ralph.sh` — the loop runner (Docker container per iteration)
- `ralph-dashboard.sh` — read-only iteration dashboard
- `ralph-live.sh` — live tail of the current iteration
- `PRD.md` — the source-of-truth product spec the loop drives toward
- `OPERATIONS.md` — maintainer-only operator runbook (gitignored)
- `SECURITY.md` — security posture + AI-generated disclosure
- `README.md` — start here for using the harness

## Workflow

1. **Open an issue first** for anything beyond a typo. Especially
   for PRD edits: changing the spec changes what the loop builds,
   so coordinate before opening a PR.
2. **Branch from `main`**. Branch names: `feat/...`, `fix/...`,
   `chore/...`, `docs/...`.
3. **Run shellcheck locally** before pushing:
   ```bash
   shellcheck -S warning ralph*.sh
   ```
   CI runs the same check on every PR.
4. **Commit convention** (F13 style — enforced loosely; mismatched
   commits get rewritten on squash-merge):
   ```
   <TYPE> [scope]: <description>           (≤ 72 characters)
   ```
   - **TYPE**: `ADD`, `RM`, `NF`, `BF`, `RF`, `DOC`
   - **scope**: `[ralph]`, `[prd]`, `[docs]`, `[repo]`, `[ci]`, etc.
   - **Only if** an AI coding agent (Claude Code, etc.) actually
     wrote or co-authored the change, end the message with the harness
     **and** the specific model that wrote it:
     ```
     Co-Authored-By: Claude Code, Opus 5
     ```
     Hand-written commits should omit this trailer.
5. **Open a PR**. Link the issue if any, describe what changed and
   why. PRs are squash-merged.

## PRD edits

`PRD.md` is the contract between the maintainer and the loop. Edits
have downstream consequences — the next loop iteration will read
your changes and act on them. Treat PRD PRs the way you'd treat a
schema migration: the diff matters, the wording matters, and the
maintainer reviews them carefully.

## What gets accepted

- **Harness bug fixes** (`ralph.sh` and friends): yes, always.
- **PRD clarifications** (typos, formatting, restructuring without
  semantic change): yes.
- **PRD scope additions** (new stories, new phases): discuss in an
  issue first.
- **New tooling around the loop** (dashboards, metrics, logging
  improvements): yes, in scope. Bash 4+ only — no Python / Node
  / Go for the harness.

## Code style

Bash 4+, `set -euo pipefail`, namespaced functions, shellcheck-clean
at warning level. Match existing patterns in the three `ralph*.sh`
scripts.

## Questions

Open an issue. The maintainer answers when they can — this is a
side project.
