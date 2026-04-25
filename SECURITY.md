# Security Notes — Ralph Loop Harness

This is **operator tooling**: it runs Claude Code with elevated permissions
in a Docker sandbox and produces commits in a sibling repo. Read this
document end-to-end before running `ralph.sh`.

---

## ⚠️  AI-generated code

**Both halves of this project are largely AI-generated.**

- The harness scripts in this repo (`ralph.sh`, `ralph-dashboard.sh`,
  `ralph-live.sh`, the PRD) were written mostly by Claude Code through
  interactive sessions on macOS and Linux, with iterative human review.
- The configurator this loop drives — at
  [revolutionaryPhoton/f13-configurator](https://github.com/revolutionaryPhoton/f13-configurator)
  — is almost entirely written by Claude Code per iteration, with human
  spot-checks on each diff but no line-by-line review.

There has been no formal security audit of either codebase.

What this means for users / contributors of either repo:

- **Don't trust generated code blindly.** Each iteration's diff has been
  shellcheck'd / bats-tested / spot-checked, but there is no line-by-line
  review and no formal security audit.
- **Read diffs before relying on anything.** Particularly anything
  involving secrets, network calls, file permissions, or shell-out
  commands built from user input.
- **Bug class to expect:** subtle parsing / escaping / permissions /
  state-machine bugs. The five regressions during S16 (paren imbalance,
  semicolon-eating regex, mktemp perms, exec-but-not-read on USER 999,
  recursive function injection) are representative — automated tests
  caught zero of them; only a human running the wizard end-to-end did.
- **If you spot something concerning, open an issue.**

---

## 🔑 Anthropic OAuth token (`CLAUDE_CODE_OAUTH_TOKEN`)

- This is a long-lived OAuth token with full Claude Code permissions on
  your Anthropic account. **Treat it like a password.**
- Generate it with `claude setup-token` (pick the long-lived option).
- Export it from your shell environment only — never paste it into a file
  in this repo, into chat, or into a CI variable that prints to logs:
  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
  ```
- `ralph.sh` forwards it into the docker container via `-e`. It is not
  written to disk inside the container, but it IS visible via
  `docker inspect` while the container runs. Don't share the host while
  a loop is in flight.
- To rotate: `claude setup-token` again, then re-export. The previous
  token can be revoked from your Anthropic account settings.

## 🔗 Discord webhook URL

- Stored in `.env.local`, sourced by `ralph.sh` at start. Anyone who
  obtains the URL can post arbitrary messages to your channel — treat
  it as a bearer token.
- `.env.local` is gitignored. **Never commit it.** Use `.env.example` as
  the template for what to put there.
- If the URL leaks: rotate it in Discord (channel settings →
  Integrations → Webhooks → regenerate or delete) and update `.env.local`.

## 🐳 Docker sandbox & `--dangerously-skip-permissions`

- The loop runs Claude Code with `--dangerously-skip-permissions` inside
  a Docker container. Inside that container, Claude can edit any file
  and run any command without prompting. That's the point — but it
  means the sandbox boundary matters.
- Mounts inside the sandbox (intentional, minimal):
  - `$(pwd):/workspace` — the configurator project (so the loop can
    edit code).
  - `~/.claude:/home/node/.claude` (read-only via subsequent copy) —
    skills + identity for the CLI.
- The sandbox does NOT mount: your shell history, ssh keys, gh
  credentials, browser profiles, or `~`. Do **not** extend the mount
  list without a clear security reason.
- Running `docker` itself requires access to the Docker socket
  (`/var/run/docker.sock`), which on most setups is equivalent to root
  on the host. Only run this loop on a machine you fully control.

## 💸 Cost & budget

- Each iteration calls the Anthropic API with the full PRD + recent
  context as input. Typical iteration cost on Opus pricing is
  ~$0.50–$5 depending on story complexity.
- A full PRD run (S00–S16) cost roughly $30–$45 at Opus pricing during
  development. Set `MAX_ITERATIONS` in `ralph.sh` to cap exposure.
- The dashboard projects estimated remaining cost based on per-story
  averages — check it before kicking off a long run.

## 🌳 Git / commit safety

- The loop commits inside the sibling configurator repo with the
  identity `David Moch <david.moch@gmail.com>` (set inside the docker
  container). Change that in `ralph.sh` if you fork.
- The loop **never pushes**. Pushing is your responsibility — review
  each iteration's diff before `git push`.
- The docker container has no GitHub credentials; push attempts inside
  the container will fail by design.

## 🚫 What this harness does NOT do

- It does not call any APIs other than Anthropic's (and optionally
  Discord, if `RALPH_DISCORD_WEBHOOK` is set).
- It does not send telemetry of its own.
- It does not require sudo.
- It does not modify files outside the repo and the configurator
  subdirectory.

## 🧹 If something feels off

- Check `ralph-logs/iteration-NNN.json` for the full stream of what
  Claude did in that iteration.
- `git -C configurator_v1 log -p` shows the actual diffs the loop
  produced.
- If a loop run made unexpected commits, you can rewind with
  `git -C configurator_v1 reset --hard <known-good-sha>` (destructive —
  back up first if unsure).
