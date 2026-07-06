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
- `ralph.sh` forwards it into both the docker container and sbx
  sandboxes via a value-less `-e CLAUDE_CODE_OAUTH_TOKEN` (the CLI
  reads the value from the environment, so it never appears on argv).
  It is not written to disk inside the container, but it IS visible via
  `docker inspect` while the container runs. Don't share the host while
  a loop is in flight.
- The token is the ONLY credential the sandbox sees — `~/.claude` is
  not mounted.
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

- The loop runs Claude Code with `--dangerously-skip-permissions`
  (configurable via `RALPH_PERMISSION_MODE`) inside a Docker container.
  Inside that container, Claude can edit any file and run any command
  without prompting. That's the point — but it means the sandbox
  boundary matters.
- **Prebuilt pinned image** (`docker/ralph.Dockerfile`, built via
  `./ralph.sh --build`): base pinned by digest, `claude-code` pinned by
  version, all toolchain deps baked. No `apt-get`, no `curl | sh`, no
  unpinned `npm install` at iteration time.
- Mounts inside the sandbox (intentional, minimal):
  - `configurator_v1/` at `/workspace` (rw) — the product repo the
    loop edits.
  - `PRD.md` at `/PRD.md` (ro) and the iteration prompt (ro).
  - **Nothing else.** The harness repo, `.env.local` (webhook) and the
    harness `.git` are not visible; `~/.claude` is NOT mounted.
- **Egress allowlist**: the image entrypoint raises a default-DROP
  iptables/ipset firewall as root (allowing only `api.anthropic.com`,
  npm and crates.io — needed by the product's backpressure checks —
  plus `RALPH_NET_ALLOW_EXTRA`), then drops to the non-root `ralph`
  user via `setpriv`. With no capabilities left, the agent cannot undo
  the rules. `RALPH_FIREWALL=off` disables it if needed.
- The container runs with `--security-opt no-new-privileges`;
  `NET_ADMIN`/`NET_RAW` are granted only so the entrypoint can raise
  the firewall before the privilege drop.
- The sandbox does NOT mount: your shell history, ssh keys, gh
  credentials, browser profiles, or `~`. Do **not** extend the mount
  list without a clear security reason.
- Running `docker` itself requires access to the Docker socket
  (`/var/run/docker.sock`), which on most setups is equivalent to root
  on the host. Only run this loop on a machine you fully control.

## 🫧 Docker Sandboxes mode (`MODE=sbx`)

- `./ralph.sh PRD.md 30 sbx` runs each iteration inside a **Docker
  Sandboxes microVM** — a hard hypervisor boundary instead of a
  shared-kernel container. Requires the standalone `sbx` CLI
  (`brew trust docker/tap && brew install docker/tap/sbx`) and a
  one-time `sbx login`; the old `docker sandbox` Desktop plugin was
  removed by Docker in mid-2026.
- Egress is locked by sbx network policies. The one-time **global
  policy** is a machine-wide decision (it applies to ALL your sbx
  sandboxes; agent kits add their own per-sandbox allows) — the
  harness therefore never initializes it silently: it aborts with
  instructions unless you opt in via `RALPH_SBX_POLICY_INIT=deny-all`.
  The loop's sandbox then gets the same allowlist as docker mode
  (`sbx policy allow network --sandbox f13-ralph ...`). Blocked
  requests receive HTTP 403.
- The sandbox mounts only `configurator_v1/` (rw, at its host path) and
  a staged copy of `PRD.md` in `.ralph-sbx/` (ro). Verified on the sbx
  CLI runtime (v0.34): no `~/.claude` credentials are copied in, and
  the github credential helper has no token to serve — pushes fail by
  design, same as docker mode.
- The template image is built on the host daemon and loaded into the
  sandbox runtime's own image store via `sbx template load`.
- The sandbox is created once and reused (persistent npm/cargo caches);
  each iteration is still a fresh claude conversation. Reset with
  `sbx rm f13-ralph`.
- `./ralph.sh --sbx-check` smoke-tests the whole setup without any API
  call (CLI + auth present, template builds and loads, toolchain
  inside, policy blocks example.com but allows api.anthropic.com).

## 💸 Cost & budget

- Each iteration calls the Anthropic API with the full PRD + recent
  context as input. Typical iteration cost on Opus pricing is
  ~$0.50–$5 depending on story complexity.
- A full PRD run (S00–S16) cost roughly $30–$45 at Opus pricing during
  development. Set `MAX_ITERATIONS` in `ralph.sh` to cap exposure.
- **Hard budget cap**: set `RALPH_MAX_BUDGET_CENTS` (e.g. `5000` =
  $50) and the loop aborts with exit 2 — before invoking Claude — once
  cumulative spend across `ralph-logs/usage-*.json` reaches the cap.
  The cap is lifetime-of-the-logdir, not per-run.
- **Runaway guard**: each iteration runs with `--max-turns` (default
  200, `RALPH_MAX_TURNS` to change, 0 to disable).
- The dashboard projects estimated remaining cost based on per-story
  averages — check it before kicking off a long run.

## 🌳 Git / commit safety

- The loop commits inside the sibling configurator repo with the
  identity `David Moch <david.moch@gmail.com>` (baked into the sandbox
  image — `ARG GIT_USER_NAME` / `GIT_USER_EMAIL` in
  `docker/ralph.Dockerfile`). Override at build time if you fork.
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
