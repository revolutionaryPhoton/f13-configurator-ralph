# PRD: F13 Shell Configurator (configurator_v1)

## Overview

A shell-based configurator that stands up a minimal F13 deployment with a
single command. Targets non-ops users who shouldn't have to hand-edit YAML
or generate secrets.

**Scope (v1 — intentionally small):**
- One preset only: `core + frontend + chat`.
- Keycloak: **guest mode on the core API + `KEYCLOAK_DISABLED=true` on the
  frontend**. No Keycloak container spun up.
- Chat backend: user picks **mock** (the shipped `ollama-mock` image) OR
  **host Ollama** (user's local `ollama serve` on the Docker host).

**Out of scope for v1:** rag, summary, parser, transcription, inference,
elasticsearch, rabbitmq, rustfs, multiple presets, a GUI, CI/CD.

Everything lives under `configurator/configurator_v1/` and is written in
bash. The configurator reads the repo's shipped config files as templates,
renders a clean copy, and runs `docker compose up` against a compose file
it generates.

## Tech Stack

| Concern          | Choice                                          |
|------------------|-------------------------------------------------|
| Language         | Bash 4+ (macOS ships 3.2 — user may need `brew install bash`) |
| YAML rendering   | `envsubst` + heredocs (no external YAML parser) |
| Prompts          | `read -r`, `select`, ANSI colors, emoji        |
| Tests            | `bats-core`                                     |
| Lint             | `shellcheck` (warning level)                    |
| Runtime deps     | docker, docker compose, bash 4+, curl, awk, sed |

No Python, no Go, no Node. One directory, scripts, templates, done.

## Success Criteria

- `./bin/f13-config` walks a first-time user from zero to a running F13 at
  `http://localhost:<chosen-port>` in ≤ 2 minutes.
- No hand-editing of YAML required.
- All six shipped secret files are generated (with safe defaults for the
  three actually needed by the minimal stack; placeholders for the rest so
  future presets drop in cleanly).
- Re-running is idempotent and non-destructive: an existing `generated/`
  directory prompts `[k]eep / [e]dit / [r]eset`.
- `shellcheck` is clean (warning level) on every tracked `.sh` file.
- `bats` suite passes.
- Works on macOS (Apple Silicon + Intel) and Linux. Windows out of scope.

---

## Mandatory Rules

These apply to every iteration of the Ralph loop.

### Backpressure

Each iteration must pass before committing:

```bash
shellcheck -S warning bin/* lib/*.sh && bats tests/
```

- All checks pass.
- Every new `.sh` file ships with at least one bats test.
- If a script has no sensible unit test, cover it with a smoke test that
  sources it and asserts on state it sets.

### Commit Convention (F13 Standard)

```
<TYPE> [scope]: <short description>   (max 72 chars)

<optional longer description>

Co-Authored-By: Claude Code
```

Types: `ADD`, `RM`, `BF`, `NF`, `DOC`, `RF`. Every commit body ends with
`Co-Authored-By: Claude Code`.

### PROGRESS.md Tracking

After every commit, update `PROGRESS.md` with completed story, commit sha,
duration, and test result. Format follows the same pattern as the previous
ralph loop.

### Code Standards

- `set -euo pipefail` at the top of every script that's executed directly.
- All functions namespaced: `ui::banner`, `prompt::yesno`, `secret::gen`.
- No `eval`. No `curl | bash`. No sudo.
- User-facing output goes through `lib/ui.sh` helpers so colors/emoji are
  centrally controlled (and can be disabled with `NO_COLOR=1`).
- German is fine for user-facing prompts; comments and variable names in
  English.
- No files outside `configurator_v1/` are modified. The configurator reads
  shipped config from `../../{core,chat,frontend}/` but never writes there.

### Directory Layout

```
configurator_v1/
  bin/
    f13-config                # main entrypoint
  lib/
    ui.sh                     # colors, emoji, boxes
    banner.sh                 # F13 ASCII art
    prompt.sh                 # ask / yesno / pickone
    secrets.sh                # random secret generator
    ports.sh                  # free-port probe
    preflight.sh              # docker / bash / curl / optional ollama checks
    render.sh                 # template renderer (envsubst)
    ollama.sh                 # host-Ollama detection + model list
    compose.sh                # docker compose up/down + health wait
    state.sh                  # read/write .state file (idempotency)
  templates/
    docker-compose.yml.tmpl   # minimal stack: frontend, core, chat, feedback-db, (ollama-mock?)
    core/general.yml.tmpl     # chat-only service_endpoints + guest_mode
    core/llm_models.yml.tmpl
    chat/general.yml.tmpl
    chat/llm_models.yml.tmpl
    env.tmpl                  # .env for port overrides
  tests/
    ui.bats
    prompt.bats
    secrets.bats
    ports.bats
    render.bats
    ollama.bats
  generated/                  # created at runtime; gitignored
    docker-compose.yml
    .env
    configs/core/
    configs/chat/
    secrets/
  README.md
  CLAUDE.md
  PROGRESS.md
  .gitignore
```

---

## User Stories

### Phase 0: Scaffolding

- [ ] **S00: Project bootstrap**
  Create the directory layout above. Add `.gitignore` that excludes
  `generated/` and `*.secret`. Add a minimal README.md with one-line intent
  ("Shell configurator for a minimal F13 deployment"). Write initial
  CLAUDE.md (ralph.sh already creates one, just verify it's sensible).
  First commit.

### Phase 1: UI Primitives

- [ ] **S01: Colors, emoji, box-drawing helpers (`lib/ui.sh`)**
  Implement:
  - `ui::red`, `ui::green`, `ui::yellow`, `ui::cyan`, `ui::dim`, `ui::bold`,
    `ui::reset` — stdout escape codes. Respect `NO_COLOR` env var.
  - `ui::ok " … "`, `ui::warn " … "`, `ui::err " … "`, `ui::info " … "`,
    `ui::step "N. …"` — prefixed one-liners with emoji (✅ / ⚠️ / ❌ / ℹ️ / 🔧).
  - `ui::hr` — horizontal rule.
  - `ui::box "Title" <<< "body"` — bordered box using `╔╗╚╝═║`.
  Bats tests: invoking each helper produces a non-empty line and the right
  substring (strip ANSI when asserting).

- [ ] **S02: F13 ASCII banner (`lib/banner.sh`)**
  `ui::banner` prints a multi-line ASCII-art "F13" logo in cyan, centered,
  followed by `   F13 · minimal configurator · v1` in dim. Use block
  characters. Must render cleanly at 80-col terminals. Bats test: banner
  prints ≥ 5 lines and contains `F13`.

- [ ] **S03: Interactive prompts (`lib/prompt.sh`)**
  - `prompt::ask VAR "Question" [default]` — reads a line into `$VAR`,
    echoes default in gray.
  - `prompt::yesno "Question" [y|n]` — returns 0 for yes, 1 for no.
  - `prompt::pickone VAR "Prompt" "opt1" "opt2" …` — numeric menu,
    rejects invalid input.
  - `prompt::secret VAR "Prompt"` — reads without echo.
  All honor `F13_CONFIG_NONINTERACTIVE=1` + env-var overrides so the
  whole wizard is scriptable (and testable). Bats tests drive this via
  piped stdin.

### Phase 2: System Integration

- [ ] **S04: Random secrets (`lib/secrets.sh`)**
  - `secret::gen [bytes]` — prints a base64url secret (default 32 bytes).
    Uses `openssl rand` if present, else `/dev/urandom` + `base64`.
  - `secret::write PATH` — generate and write with `chmod 600`.
  - Idempotent: if file exists, do not overwrite unless `--force`.
  Bats: generates unique values; file is 0600.

- [ ] **S05: Port probes (`lib/ports.sh`)**
  - `ports::is_free PORT` — returns 0 if `lsof -iTCP:PORT -sTCP:LISTEN`
    finds nothing (or `ss -ltn` fallback on Linux).
  - `ports::pick_free PREFERRED FALLBACK_RANGE…` — returns preferred if
    free, else next free port in the range.
  Bats: `ports::is_free 1` should be 1 (privileged/likely taken).

- [ ] **S06: Preflight (`lib/preflight.sh`)**
  `preflight::run` checks in order and prints ✅ / ❌ per check:
  1. `docker` on PATH and `docker info` succeeds.
  2. `docker compose version` prints something.
  3. bash ≥ 4.0 (check `${BASH_VERSINFO[0]}`).
  4. `curl`, `awk`, `sed`, `envsubst` on PATH.
  5. ~2 GB free on `$PWD`.
  On any failure, print an install hint and exit 1. Bats test runs with
  PATH stubs.

- [ ] **S07: Host Ollama integration (`lib/ollama.sh`)**
  - `ollama::is_running` — `curl -fsS http://localhost:11434/api/tags` in
    < 2s. Returns 0/1.
  - `ollama::list_models` — parses the tags JSON and prints model names,
    one per line. No `jq` — use `grep`/`sed`.
  - `ollama::host_url_for_docker` — prints the URL the chat container
    should hit. On macOS: `http://host.docker.internal:11434/v1`. On
    Linux: same, but compose must inject `extra_hosts:
    host.docker.internal:host-gateway` (handled in the compose template).
  Bats: mock `curl` via a PATH stub and assert parsing.

### Phase 3: Templates and Rendering

- [ ] **S08: Template renderer (`lib/render.sh`)**
  - `render::file SRC DEST` — runs `envsubst` on SRC with an allow-list of
    vars (no shell metachars leak into YAML).
  - `render::tree templates/ generated/` — mirrors the template dir.
  Bats: render a fixture template and diff against expected output.

- [ ] **S09: Compose + config templates**
  Populate `templates/` with the minimal stack. All vars `${LIKE_THIS}`
  are substituted.

  **`docker-compose.yml.tmpl`** (services only — no `version:` key, it's
  obsolete):
  - `frontend`: image `registry.opencode.de/f13/microservices/frontend/main:latest`,
    `KEYCLOAK_DISABLED=true`, ports `${FRONTEND_PORT}:9999`, depends on core.
  - `core`: same image as shipped, mounts `./configs/core:/core/configs`
    and `./secrets:/run/secrets`, ports `${CORE_PORT}:8000`, depends on
    `chat` and `feedback-db`.
  - `chat`: image `registry.opencode.de/f13/microservices/chat/main:latest`
    (or local build — detect via `CHAT_IMAGE` var), mounts
    `./configs/chat:/chat/configs`, `extra_hosts:
    host.docker.internal:host-gateway` when `CHAT_BACKEND=ollama`.
  - `feedback-db`: postgres:16-alpine, env vars for DB + password from
    generated secret, healthcheck `pg_isready`.
  - `ollama-mock`: included only when `CHAT_BACKEND=mock` (use a profile
    or conditional render).

  **`core/general.yml.tmpl`**: copy of `core/configs/general.yml` but
  `service_endpoints` contains only `chat`, `active_llms.chat` contains
  only `${CHAT_MODEL_ID}`, `authentication.guest_mode: true`,
  `allow_origins` uses `${FRONTEND_PORT}`.

  **`chat/general.yml.tmpl`** + **`chat/llm_models.yml.tmpl`**: include
  exactly one model entry:
  - If `CHAT_BACKEND=mock`: `test_model_mock` pointing to
    `http://ollama-mock:11434/v1` with model `test_model:mock`.
  - If `CHAT_BACKEND=ollama`: a single entry named `local_ollama`
    pointing to `http://host.docker.internal:11434/v1`, model
    `${OLLAMA_MODEL}`, `max_context_tokens: 8192`.

  **`env.tmpl`**: all `${VARS}` the wizard fills, used by docker compose
  via `--env-file`. Includes `FRONTEND_PORT`, `CORE_PORT`, `CHAT_BACKEND`,
  `OLLAMA_MODEL`, `CHAT_MODEL_ID`, `FEEDBACK_DB_PASSWORD`.

  Bats: render with a fixture set of env vars, assert the output is
  valid YAML (via `python3 -c 'import yaml,sys;yaml.safe_load(sys.stdin)'`
  OR `docker compose -f <rendered> config --quiet` if docker is available;
  skip the test on machines without either).

### Phase 4: Wizard + Launch

- [ ] **S10: Main wizard (`bin/f13-config`)**
  The single entrypoint. Flow:
  1. `ui::banner`
  2. `preflight::run`
  3. Announce the preset (core + frontend + chat, Keycloak guest mode)
     and confirm with `prompt::yesno`.
  4. Chat backend pick:
     ```
     Where should chat inference run?
       1) 🧪 Mock backend (no GPU, deterministic responses)
       2) 🦙 Host Ollama (connects to ollama serve on this machine)
     ```
     If Ollama: call `ollama::is_running`. If not running, print how to
     start it (`ollama serve`) and loop. Then `ollama::list_models` and
     `prompt::pickone` to pick a model (default pre-filled with
     `gemma4:31b-cloud` if present, else first in list).
  5. Port pick: `ports::pick_free 9999` for frontend, `8000` for core.
     Allow override via prompt.
  6. Generate secrets for feedback-db and (placeholders for) llm_api,
     transcription_db, rabbitmq, rustfs, huggingface_token. Write to
     `generated/secrets/`.
  7. Render templates into `generated/`.
  8. Print a summary box: preset, backend, model, ports, paths.
  9. `prompt::yesno "Start it now?"` — if yes, run `compose::up`.

  Flags:
  - `--non-interactive` → drives the wizard from env vars. All defaults
    documented in `--help`.
  - `--reset` → wipe `generated/` (with confirmation).
  - `--dry-run` → render but don't launch.

  Bats: invoke with `F13_CONFIG_NONINTERACTIVE=1` + full env, assert
  `generated/` is produced and contains the expected files.

- [ ] **S11: Launch + health wait (`lib/compose.sh`)**
  - `compose::up` — runs `docker compose --env-file .env up -d` in
    `generated/`.
  - `compose::wait_healthy` — polls `core` health at `http://localhost:
    ${CORE_PORT}/health` for up to 120s, prints a ⏳ spinner.
  - `compose::down` — clean shutdown.
  - On success, prints a big green box:
    ```
    ✅ F13 is up!
       Frontend:  http://localhost:${FRONTEND_PORT}
       API:       http://localhost:${CORE_PORT}
       Stop:      cd configurator_v1/generated && docker compose down
    ```
  Bats: skip unless `docker info` works (mark `skip`).

- [ ] **S12: Idempotency + re-run (`lib/state.sh`)**
  - On start, if `generated/.state` exists, read it and print the current
    config, then prompt `[k]eep existing / [e]dit (re-run wizard with
    current values as defaults) / [r]eset (delete generated/ and start
    over)`.
  - `.state` is a simple `KEY=VALUE` file written at the end of a
    successful render. Keys: `PRESET`, `CHAT_BACKEND`, `OLLAMA_MODEL`,
    `FRONTEND_PORT`, `CORE_PORT`, timestamp.
  Bats: write a fake state, assert the three paths behave correctly.

### Phase 5: Polish

- [ ] **S13: Shellcheck clean-up**
  Run `shellcheck -S warning bin/* lib/*.sh` across the whole tree. Fix
  every warning. If a specific line truly needs an exception, add a
  narrow `# shellcheck disable=…` with a justification comment above.
  Commit.

- [ ] **S14: README.md**
  User-facing docs at `configurator_v1/README.md`. Must cover:
  - What this is and what preset it installs.
  - One-paragraph quickstart: `cd configurator_v1 && ./bin/f13-config`.
  - Requirements (docker, bash 4+, curl, free disk, open ports 8000/9999).
  - The two chat backend options explained (mock vs Ollama). Example
    output of each prompt.
  - How host Ollama is reached from inside Docker (the
    `host.docker.internal` trick, explicit for Linux users).
  - How to stop / reset / re-run.
  - Known limitations (single preset, no RAG, no auth UI).
  - A "what's generated" section showing the `generated/` tree.
  Commit.

- [ ] **S15: Demo transcript**
  Record a plain-text transcript of a full run (mock backend) and save
  as `docs/demo-transcript.txt`. Keep it tiny; just enough to show the
  UX. Commit.

### Phase 6: Frontend feature gating

- [ ] **S16: Build a patched frontend image with feature gating**

  **Problem:** The shipped frontend image always shows all features
  (chat, RAG, summary, transcription) when `KEYCLOAK_DISABLED=true`
  because `UIStore.js` hardcodes them all on. The configurator only
  launches `core + frontend + chat`, so the other tabs are dead links.

  **Approach:** Obtain the frontend source (from the local monorepo if
  available, otherwise clone from GitLab), apply a minimal patch to
  `UIStore.js` and `docker-entrypoint.sh`, build a local Docker image,
  and reference it in the generated compose file instead of the registry
  image.

  **Exact patch — `src/utils/UIStore.js` lines 27–34:**

  The current code (hardcoded defaults when Keycloak is disabled):
  ```js
  : // If Keycloak is disabled, most features are enabled by default
    writable({
      chat: true,
      recherche: true,
      askTheText: false,
      summary: true,
      transcription: true,
      feedback: true,
    })
  ```

  Replace with a read from `window.APP_CONFIG.ENABLED_FEATURES`
  (a comma-separated list injected at container start, e.g. `"chat"`):
  ```js
  : // If Keycloak is disabled, features are driven by ENABLED_FEATURES
    writable((() => {
      const enabled = (
        (typeof window !== 'undefined' &&
          window.APP_CONFIG &&
          window.APP_CONFIG.ENABLED_FEATURES) || 'chat,recherche,askTheText,summary,transcription,feedback'
      ).split(',').map(f => f.trim());
      return {
        chat:          enabled.includes('chat'),
        recherche:     enabled.includes('recherche'),
        askTheText:    enabled.includes('askTheText'),
        summary:       enabled.includes('summary'),
        transcription: enabled.includes('transcription'),
        feedback:      enabled.includes('feedback'),
      };
    })())
  ```

  The default value (`'chat,recherche,...'`) preserves existing behaviour
  when `ENABLED_FEATURES` is not set, so the patch is backwards-compatible.

  **Entrypoint patch — `scripts/docker-entrypoint.sh`:**

  Add `ENABLED_FEATURES` to the `generate_config_script` function
  alongside the existing vars. The field is written into `window.APP_CONFIG`
  so the patched `UIStore.js` can read it at runtime:
  ```sh
  enabled_features=$(escape_js_string "${ENABLED_FEATURES:-chat,recherche,askTheText,summary,transcription,feedback}")
  # add to the APP_CONFIG object:
  # ENABLED_FEATURES:"${enabled_features}"
  ```

  **Steps the story must implement:**

  1. **`lib/frontend.sh`** — new lib file:

     - `frontend::get_source DEST_DIR` — resolves the frontend source:
       1. If `../../frontend/src` exists (local monorepo), copy the whole
          `../../frontend/` tree into `DEST_DIR`.
       2. Otherwise, `git clone --depth 1 https://gitlab.opencode.de/f13/microservices/frontend.git DEST_DIR`.
       Fails fast with a clear message if neither git nor the local path
       is available.

     - `frontend::clone_required` — returns 0 if `../../frontend/src`
       does NOT exist (i.e. a git clone will be needed). Used by preflight
       to conditionally check that `git` is on PATH.

     - `frontend::patch_and_build IMAGE_TAG` — orchestrates the full build:
       1. Create a temp working dir (`mktemp -d`).
       2. Call `frontend::get_source` to populate it.
       3. Apply the `UIStore.js` patch with `awk` (match the exact block
          and replace it; do not use line-number assumptions — match by
          content so upstream edits don't silently break the patch).
       4. Apply the `docker-entrypoint.sh` patch with `sed`.
       5. Run `docker build -t "${IMAGE_TAG}" .` inside the temp dir.
       6. Clean up the temp dir on exit (trap ERR + EXIT).

     - `frontend::image_exists IMAGE_TAG` — returns 0 if the local image
       already exists (`docker image inspect`), used for cache check.
     - `IMAGE_TAG` format: `f13-frontend:configurator-v1`

  2. **`lib/preflight.sh` addition:**
     - Add a conditional check: if `frontend::clone_required` returns 0,
       verify `git` is on PATH and can reach
       `https://gitlab.opencode.de/f13/microservices/frontend.git`
       (`git ls-remote --exit-code URL HEAD` with a 10s timeout).
       Print ✅ `git (clone required — remote reachable)` or
       ❌ with install hint and exit 1.

  3. **`bin/f13-config` integration:**
     - After the port step and before secret generation, add a build step:
       `🔨  Building patched frontend image…` (skipped with `--dry-run`).
     - Compute `ENABLED_FEATURES` from the preset. For v1 the preset is
       always `core+frontend+chat`, so `ENABLED_FEATURES="chat"`.
     - If the image already exists, prompt:
       `Patched frontend image found. Rebuild? [y/N]` — default N (use cache).
     - Pass `ENABLED_FEATURES` and `FRONTEND_IMAGE` into the render vars.

  4. **`templates/docker-compose.yml.tmpl`:**
     - Frontend service: replace the hardcoded registry image with
       `${FRONTEND_IMAGE}` and add `ENABLED_FEATURES: "${ENABLED_FEATURES}"`.
     - Remove `platform: linux/amd64` from the frontend service — the local
       build produces a native arm64 image on Apple Silicon.

  5. **`templates/env.tmpl`:**
     - Add `FRONTEND_IMAGE` and `ENABLED_FEATURES` vars.

  6. **`bin/f13-rebuild-frontend`** — standalone script:
     - Forces a rebuild of the patched frontend image (ignores cache).
     - Useful after pulling a new upstream frontend image or after the
       upstream repo changes.
     - Prints `./bin/f13-config` as the next step.

  7. **Tests (`tests/frontend.bats`):**

     Source-acquisition + image-existence tests:
     - Mock `docker build`, `git clone`, and `docker image inspect`.
     - `frontend::get_source` prefers local path over clone when
       `../../frontend/src` exists.
     - `frontend::get_source` runs `git clone` with the correct URL when
       the local path is absent.
     - `frontend::image_exists` returns 0 / 1 with a mocked `docker image
       inspect`.

     Patch-correctness tests (run against a real fixture `UIStore.js` and
     `docker-entrypoint.sh` checked into `tests/fixtures/`).
     **These cover the five regressions hit during S16 bringup — every
     bullet must have a dedicated bats test:**

     UIStore.js patch:
     - **Paren balance:** total `(` count equals total `)` count after
       patching. Asserts the IIFE wraps inside `writable(...)` close
       cleanly: `writable((() => {...})())`.
     - **Statement terminator:** the patched block ends with `})());`
       (closing IIFE call, closing `writable(`, semicolon). The
       skip-stop regex must accept the original `    });` line.
     - **Default export preserved:** `grep '^export default'` still
       matches in the patched file. (Original bug: skip block ate the
       rest of the file when `});` semicolon was present.)
     - **Line count delta:** patched file is ~7 lines longer than
       original (the size of the replacement minus the size of the
       original block). Sanity check that we didn't truncate or duplicate.

     docker-entrypoint.sh patch:
     - **No injection inside function definitions:** the line
       immediately after `escape_js_string() {` must be `local input=` —
       NOT `enabled_features=$(escape_js_string ...)`. (Original bug
       caused infinite recursion when the function ran.)
     - **Two `ENABLED_FEATURES` occurrences:** one as a variable
       assignment inside `generate_config_script`, one inside the
       single-line `APP_CONFIG={...}` object. (Original bug: the
       multi-line state machine never fired on the heredoc one-liner,
       so APP_CONFIG never got the field.)
     - **Bash syntax check:** `bash -n` on the patched entrypoint
       returns 0.
     - **Permissions are 0755:** `stat -f '%Lp'` (macOS) / `stat -c '%a'`
       (Linux) on the patched file returns `755`. (Original bug:
       `mktemp` perms were 0600, `chmod +x` produced 0711, and
       `USER 999` in the image could execute but not READ the script
       because "others" had only `--x`.)

  **Backpressure:** `shellcheck -S warning bin/* lib/*.sh && bats tests/`
  must pass. The docker build itself is integration-only and may be skipped
  in CI with `F13_SKIP_BUILD=1`.

  **Note:** `../../frontend/` is read-only source. The patch is applied to
  a temp copy; the original is never modified.

### Phase 7: Desktop GUI

A cross-platform desktop wrapper around the existing shell wizard, so
non-shell users (PMs, POs, demo audiences) can click through the same
flow on macOS or Linux. Shares the same engine — the GUI is a UI surface,
not a re-implementation.

**Stack:**
- **Tauri 2.x** for the desktop shell (small binary, system webview).
- **Svelte 5 + Vite + Tailwind CSS 4** for the UI, matching the F13
  frontend stack so the design system imports cleanly.
- **TypeScript** strict mode, no `any`.
- **Vitest + @testing-library/svelte** for component tests.

**Repo layout:**
- The GUI lives at `configurator_v1/gui/` (sibling of `bin/`, `lib/`,
  `templates/`, `tests/`). One repo, two surfaces.
- The GUI vendors no engine logic of its own. It shells out to the
  existing scripts via Tauri's `Command` API and parses their output.
- A future Phase 8 can extract the engine into a TypeScript / Rust
  library that both the CLI and GUI call as a function. Out of scope
  here.

**Audience and constraints (v1 GUI):**
- Sysadmins doing first deployment on their laptop. CLI-fluent, but
  benefit from a one-window flow.
- PMs / POs running click-through demos on macOS or Linux desktops.
- Single-instance demo only. No deployment-host / headless / auto-update
  yet.
- The shell wizard at `bin/f13-config` stays first-class — must keep
  working without the GUI for SSH, CI, and scripting.

**Mandatory rules (extension of Phase 0–6 rules):**
- Invoke `/frontend-design-v2` skill before writing any `.svelte` file
  with UI. Same as the original frontend rules. No exceptions.
- Backpressure for GUI stories — **all headless, no display required**:
  ```bash
  cd gui && npm run check && npm run test:unit && cargo check
  ```
  Plus the original shell backpressure (`shellcheck` + `bats`) for any
  changes outside `gui/`.
- 🚫 **The loop must NEVER run** `npm run tauri dev`, `tauri dev`,
  `cargo run`, or any Tauri WebDriver E2E command. The loop runs in
  a headless Docker sandbox with no display — those commands would
  hang forever waiting for a window, blocking the iteration. Visual
  and interactive verification is the maintainer's job, on macOS,
  outside the loop.
- 🍎 **macOS is the only validated target until Phase 8.** Tauri code
  is naturally cross-platform and may target Linux/WSL too, but no
  Linux validation happens inside the loop (the loop has no display)
  or in CI (CI matrix is macOS-only for Phase 7). Linux build deps
  may be documented in `gui/CONTRIBUTING.md` for future reference but
  must NOT be the gating success criterion of any story.
- Coverage ≥ 75 % on new/modified TS/Svelte files (lower than v1's 80 %
  because Tauri integration paths are hard to unit-test).
- Never call docker / shell commands directly from Svelte components.
  All side effects route through the engine adapter (S18) so they're
  testable.
- The Tauri allowlist (`tauri.conf.json` -> `app.security.csp` and
  `permissions/`) is restrictive by default. Each new shelled-out
  command requires an explicit permission entry.

**Story list (S17 — S31):**

- [ ] **S17: Tauri scaffolding + dev workflow (macOS-validated)**

  Inside `configurator_v1/gui/`, scaffold a Tauri 2.x app:
  - `npm create tauri-app@latest` with template `svelte-ts`.
  - Configure: Vite, TypeScript strict, Tailwind CSS 4, Vitest,
    Biome (matching F13 frontend conventions).
  - **Loop-side validation (must pass headless):**
    - `npm install`, `cargo fetch` complete cleanly.
    - `npm run check` (svelte-check + biome) passes.
    - `cargo check` passes.
    - `npm run test:unit` runs (even if just a placeholder test).
  - **Maintainer-side validation (NOT done inside the loop):**
    - `npm run tauri dev` opens a hello-world window on macOS.
    - The maintainer notes any first-run install hiccups in
      `gui/CONTRIBUTING.md`.
  - **The ralph image** needs Rust *and* the Tauri compile-time apt
    deps so `cargo check` passes inside the headless Linux container
    (Tauri 2's crates link against GTK/WebKit even at compile time;
    these are needed even when no window is ever opened):
    - `rustup` install via the official one-liner (`curl … | sh -s --
      --default-toolchain stable -y`).
    - apt: `libwebkit2gtk-4.1-dev`, `libglib2.0-dev`, `libgtk-3-dev`,
      `libssl-dev`, `build-essential`, `librsvg2-dev`, `patchelf`,
      `libsoup-3.0-dev`, `libjavascriptcoregtk-4.1-dev`.
    - Add to `ralph.sh`'s `docker run` bootstrap. Document the same
      list in `gui/CONTRIBUTING.md` for human maintainers on Linux.
  - **macOS-side maintainer setup** — separately documented in
    `gui/CONTRIBUTING.md`: Xcode CLI Tools, `rustup`, no extra
    Homebrew packages required for development. (Tauri uses the system
    WebKit framework on macOS, which ships with the OS.)
  - Linux verification of the GUI itself (running, building debug
    bundle, end-to-end testing) is **deferred to Phase 8**. Phase 7
    targets macOS for visual / interactive validation; the loop only
    exercises the Linux compile path because that's where it runs.
  Commit.

- [ ] **S18: Engine adapter (`gui/src/lib/engine.ts`)**

  Typed wrapper that shells out to the existing CLI:
  - `engine.preflight()` → streams ✅/❌/ⓘ events.
  - `engine.detectState()` → returns existing `.state` or null.
  - `engine.listOllamaModels()` → string[] or 'not-running'.
  - `engine.checkPort(n)` → 'free' | { inUseBy: PID, name }.
  - `engine.runWizardNonInteractive(opts)` → streams pipeline events
    (rendering, building, pulling, starting, healthy).
  - `engine.compose.up()`, `engine.compose.down()`,
    `engine.compose.reset()`, `engine.compose.health()`.

  Implementation: each method invokes `bin/f13-config` (or
  `bin/f13-stop`, `bin/f13-reset`) via Tauri's `Command::sidecar` with
  `F13_CONFIG_NONINTERACTIVE=1` and parses stdout/stderr. Output uses
  a single-line JSON event format (this is also a story output: the
  CLI gains an `--emit-events` flag in S18 that prints structured
  events to stdout instead of pretty text).

  **CLI changes required for S18:**
  - Add `--emit-events` flag to `bin/f13-config` that switches stdout
    from `ui::*` text helpers to one JSON object per line:
    `{"type":"preflight","name":"docker","status":"ok"}` etc.
  - All other binaries (`f13-stop`, `f13-reset`,
    `f13-rebuild-frontend`) gain the same flag.
  - Behavior of pretty mode is unchanged.

  Vitest: subprocess mocked with a fixture stream of JSON events; assert
  the adapter emits typed events to its consumers.
  Commit.

- [ ] **S19: Design system import (`gui/src/lib/theme/`)**

  Invoke `/frontend-design-v2` skill before writing any UI.
  Bring over (or reproduce) from the F13 frontend:
  - `tokens.css` — F13 color palette, light + dark.
  - Ubuntu font face declarations.
  - Logos / favicon copied from `../frontend/public/logos/`.
  - Base components: `Button.svelte`, `Tile.svelte` (the big tile from
    the inference picker), `RadioRow.svelte`, `ProgressBar.svelte`,
    `Disclosure.svelte`, `LogViewer.svelte`, `Modal.svelte`, `Toast.svelte`.
  - Tailwind CSS 4 configured to consume CSS custom properties from
    `tokens.css`.

  All components must pass WCAG 2.2 AA contrast checks. Vitest + axe-core
  smoke test on each.
  Commit.

- [ ] **S20: Welcome screen + state-aware routing**

  Invoke `/frontend-design-v2` skill before writing any UI.
  Implement `gui/src/routes/+page.svelte`:
  - F13 ASCII logo (or SVG version), tagline, primary "Begin setup" CTA.
  - "Open existing setup" link calls `engine.detectState()`. If a state
    file exists, route to `/status`. If not, the link is hidden.
  - Mockup reference: section 1 of the GUI sketch.
  Component test: with state-present and state-absent fixtures, assert
  routing.
  Commit.

- [ ] **S21: Preflight screen**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/wizard/preflight/+page.svelte`:
  - Streaming check list driven by `engine.preflight()` events.
  - Hard failures (docker missing, etc.): inline "Fix this" disclosure
    that pastes the install command (cmd + key, or one-click copy).
  - Soft notes (Ollama detection): rendered as ⓘ rows with the model
    list nested. Doesn't block continuation.
  - "Continue" disabled until the stream finishes; remains disabled if
    a hard failure exists.
  Mockup reference: section 2.
  Component test: feed scripted event streams, assert UI state at each.
  Commit.

- [ ] **S22: Inference picker**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/wizard/inference/+page.svelte`:
  - Two large `Tile.svelte` components: 🧪 Mock, 🦙 Ollama.
  - Pros / cons list inside each tile.
  - "Recommended for first-time setup" chip on Mock.
  - Selecting Ollama enables the next step (S23); selecting Mock skips
    to ports (S24).
  Mockup reference: section 3.
  Component test: click events change selected state; outcome events
  are dispatched.
  Commit.

- [ ] **S23: Ollama model picker**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/wizard/inference/ollama/+page.svelte`:
  - Warning banner at top: GPU requirements + cloud-tag sign-in note
    (matches the shell wizard's S07/S22 warning).
  - List from `engine.listOllamaModels()`. Cloud-tagged models get a
    `☁ cloud` badge; local models show disk size if available.
  - "Refresh" link re-runs `engine.listOllamaModels()` (handy after
    `ollama pull`).
  - If Ollama is not running, render a different state with start-it
    instructions and a retry button.
  Mockup reference: section 3b.
  Commit.

- [ ] **S24: Ports screen**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/wizard/ports/+page.svelte`:
  - Two number inputs, default 9999 / 8000.
  - Live `engine.checkPort()` on blur; ✅ free / ❌ in-use-by-PID inline.
  - "Advanced" disclosure (S28-territory): exposes secret-file paths
    and a placeholder "Edit system prompt" button (greyed out — that's
    the roadmap "Custom system prompts" item).
  - "Continue" disabled while any port shows ❌.
  Mockup reference: section 4.
  Commit.

- [ ] **S25: Build / launch pipeline**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/wizard/run/+page.svelte`:
  - Vertical pipeline of steps: Generating secrets → Rendering compose
    → Building patched frontend → Pulling images → Starting containers
    → Waiting for health.
  - Each step has its own indicator (◯ pending, ⏳ running, ✅ done,
    ❌ failed) and an optional collapsible log via `LogViewer.svelte`.
  - The frontend build step gets a determinate progress bar parsed from
    docker build output (best-effort; fall back to indeterminate).
  - "Cancel" sends SIGTERM to the running subprocess and rolls back
    via `engine.compose.down()`.
  - On success, navigate to `/status`.
  Mockup reference: section 5.
  Commit.

- [ ] **S26: Status screen + actions**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/status/+page.svelte`:
  - Health row per service (`engine.compose.health()` polled every 5 s).
  - Primary CTA: "Open F13 in browser" (opens default browser at
    `localhost:${FRONTEND_PORT}` via `tauri://opener`).
  - Secondary actions: View logs, Stop F13, Full reset.
  - Each action streams its progress in a sticky toast.
  Mockup reference: section 6.
  Commit.

- [ ] **S27: Confirmations + edge cases**

  Invoke `/frontend-design-v2` skill.
  - Reset confirmation modal (irreversible action — explicit "Type RESET
    to confirm" or simple double-confirm).
  - Port-collision modal with a "Pick another port" path.
  - "F13 is already running" detection on app start with a "Show status"
    or "Stop & reconfigure" choice.
  Commit.

- [ ] **S28: Settings panel**

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/settings/+page.svelte`:
  - View generated config (read-only). Copy buttons for the YAML files.
  - Edit-prompt entry point (still grey/disabled in v1 — wired to the
    "Custom system prompts" roadmap item; ships as a no-op modal that
    explains the feature is coming).
  - Theme toggle (light / dark / system).
  Commit.

- [ ] **S29: Packaging infrastructure (macOS only, no distributable artifacts)**

  Goal: every piece needed to *eventually* produce a macOS installer is
  in place and validated by a local debug build, but **no `.dmg` is
  shipped**. Linux packaging and any signed artifacts are deferred to a
  future Phase 8.

  In scope for S29:
  - **`gui/src-tauri/tauri.conf.json` bundle config:**
    - `productName`, `identifier` (`de.f13-os.configurator` — confirm
      with the maintainer), `version`, `category`, `shortDescription`,
      `longDescription`.
    - Bundle target list set to `[]` (intentionally empty, so
      `tauri build` produces only the binary / `.app`, no installers).
  - **App icons** — generate the full Tauri icon set
    (`gui/src-tauri/icons/`) from a single 1024×1024 source (use
    `tauri icon` CLI). The macOS `.icns` is the must-have output;
    `.png` outputs are produced as a side effect and may be retained
    for the future Linux phase.
  - **Sidecar resource bundling** — declare `bin/f13-config`,
    `bin/f13-stop`, `bin/f13-reset`, `bin/f13-rebuild-frontend`, plus
    `lib/` and `templates/`, as Tauri resources. Engine adapter (S18)
    resolves paths via `app.path().resource_dir()` so it works in both
    `tauri dev` and `tauri build` modes. Add a Vitest that asserts
    the resolved path exists in both modes.
  - **`tauri build --debug`** must succeed when run *on the maintainer's
    macOS machine* (Apple Silicon to start). The output is a runnable
    `.app` the maintainer can launch directly. **The loop does not run
    `tauri build`** — only `cargo check` is in headless backpressure.
  - **CI workflow stub** — `.github/workflows/gui-build.yml` exists and
    runs `tauri build --debug` on `macos-latest` only. Does NOT
    publish artifacts. This is the smoke test that the packaging
    config doesn't drift; releasing is Phase 8's job.

  **Explicitly out of scope for S29 (deferred to a future Phase 8):**
  - Linux Tauri builds (any `.AppImage`, `.deb`, or running the GUI on
    Linux at all). The GUI is macOS-only until the maintainer has
    Linux validation cycles.
  - Producing signed/notarized `.dmg` for macOS distribution.
  - Apple Developer ID signing, notarization.
  - GitHub Releases automation.
  - Auto-update flow.
  Commit.

- [ ] **S30: GUI README + screenshots + CHANGELOG**

  - `gui/README.md`: stack, dev setup, packaging, troubleshooting.
  - Screenshots / animated GIFs of the wizard flow.
  - Top-level `README.md`: add a "GUI vs CLI" table so users know
    which surface to pick.
  - CHANGELOG.md at repo root: notes for the GUI release.
  Commit.

- [ ] **S31: End-to-end smoke test (maintainer-only, not loop-runnable)**

  - `gui/tests/e2e/smoke.spec.ts` using Tauri's WebDriver mode.
  - Click through Welcome → Preflight → Inference (mock) → Ports
    (defaults) → Run pipeline → Status.
  - Assert a real container stack comes up and `core /health` returns
    200. Tear down at the end.
  - **Runs on the maintainer's macOS machine only.** Tauri WebDriver
    needs a display and a real Tauri app process — neither exists in
    the loop's headless Linux Docker container. The test is gated
    with an environment guard (`F13_E2E=1` or similar) so it doesn't
    run during loop iterations or in macOS-only CI either (the CI
    runner has no Docker for the F13 stack).
  - Story acceptance: the test file exists, is documented in
    `gui/tests/e2e/README.md`, and the maintainer ran it once locally
    and recorded the output.
  Commit.

### Phase 7.5: GUI bug-fixing pass (loop-verifiable subset)

Two of the five v0.2.x bugs can be verified end-to-end by the loop's
headless checks (bash + bats + cargo check + vitest). The remaining
three need a real running app to prove the fix worked, so they're
broken out into the *Maintainer hand-fixes* section below and worked
on interactively between the maintainer and me — not by the loop.

The same Phase 7 mandatory rules apply (headless backpressure,
no `tauri dev` / `cargo run` / window-opening commands, macOS-only
target, invoke `/frontend-design-v2` before any new `.svelte` UI).
Each story lands as its own `BF [gui]` commit.

- [ ] **S32: `f13-reset` honours `F13_GENERATED_DIR`**

  **Bug:** `bin/f13-reset` only wipes `configurator_v1/generated/`
  (the shell wizard's default `GEN_DIR`). When the GUI invokes the
  reset path it writes to `gui/src-tauri/target/debug/generated/`,
  so the GUI's stale state survives every reset attempt and re-runs
  hit the half-rendered config.

  **Fix:**
  - `bin/f13-reset` already references `F13_GENERATED_DIR` via
    `${F13_GENERATED_DIR:-${SCRIPT_DIR}/../generated}` — verify the
    plumbing actually wipes a custom directory and add a bats test
    that creates a fixture dir under `mktemp`, runs
    `F13_GENERATED_DIR=… ./bin/f13-reset`, asserts the dir is gone.
  - Apply the same audit to `bin/f13-stop`.
  - The engine adapter (`gui/src/lib/engine.ts compose.reset`)
    already passes `F13_GENERATED_DIR` — confirm via vitest that
    the env-var actually reaches the spawned subprocess.

  **Loop-verifiable acceptance:** new bats test passes; existing
  vitest passes; `shellcheck` clean.

- [ ] **S34: Wizard's `keep` path emits per-stage events**

  **Bug:** when `.state` exists, the wizard skips
  secrets/render/build/pull/health and only emits
  `{type:"step", name:"start", ...}`. The GUI's six-stage pipeline
  graph stays pending forever — looks "stuck" even though docker
  compose is actually starting underneath.

  **Fix (CLI side, in `bin/f13-config`):**
  - In `wizard()`'s `keep` branch, before calling `compose::up`,
    emit synthetic `{type:"step", name:<each prior stage>,
    status:"done", skipped:true}` events so the GUI can fill the
    graph instantly.
  - Add a helper `events::emit_skipped <name>` in
    `lib/events.sh` to keep the JSON shape consistent.
  - Bats test: run the wizard with a stale state file +
    `--emit-events` and assert every stage's `done` event with
    `skipped:true` appears in stdout.

  **Fix (GUI side, in `gui/src/routes/wizard/run/+page.svelte`):**
  - Treat `step.skipped === true` as instantly done — no progress
    animation. Render a faded checkmark with a tooltip
    "skipped — existing state".
  - Vitest: feed a fixture event stream containing skipped events
    and assert the pipeline graph fills without delay.

  **Loop-verifiable acceptance:** new bats + new vitest pass;
  `cargo check`, `npm run check` clean.

---

## Maintainer hand-fixes (between v0.2.x and v0.3.0)

These three sit outside the loop because their acceptance criteria
require seeing the actual running app. Worked interactively between
the maintainer and me; each lands as a `BF [gui]` commit. They count
toward v0.2.2 alongside the loop's S32 + S34 — when all five are
shipped, the macOS GUI is considered the first trustable desktop
release.

- **HF1: GUI uses an absolute `generatedDir`.** The current relative
  default (`"./generated"`) resolves against the Tauri dev process's
  CWD (`gui/src-tauri/target/debug/`) instead of an obvious path
  under `configurator_v1/`. Fix: add a Rust `get_generated_dir()`
  command that mirrors `get_bin_dir()`; `bootstrap.ts` reads it
  once and stashes it; all wizard pages default to that constant.
  **Hand-verifiable:** after a fresh GUI run, the stack lives at
  `configurator_v1/generated/` and `./bin/f13-stop` from the shell
  tears it down.

- **HF2: Cancel button actually aborts the subprocess.** Currently
  `handleCancel()` only flips a JS-side `cancelToken`; the bash
  process keeps running and can finish a half-built docker stack.
  Fix: `tauriRunner.ts` returns a kill handle from `runner.run()`;
  the engine propagates it through `runWizardNonInteractive` and
  `compose.up`; the run page calls `kill()` then `compose.down()`.
  **Hand-verifiable:** Cancel mid-pipeline drops the bash process
  within 2s (visible via `ps -ef | grep f13-config`) and leaves
  no orphan containers (`docker ps`).

- **HF3: Eliminate sporadic "pull access denied" on `f13-frontend`.**
  Compose occasionally tries to pull the locally built
  `f13-frontend:configurator-v1` image instead of using the local
  one. Fix candidates: add `pull_policy: never` to the frontend
  service in the compose template; add a `docker image inspect`
  precondition before `compose::up` that surfaces a clear
  "frontend image missing" error instead of letting compose
  blunder into a failed pull.
  **Hand-verifiable:** ten consecutive fresh cycles
  (reset → setup → status → reset) produce zero pull-related
  compose errors. Cannot be automated without spinning real
  containers in CI.

---

## Release roadmap

The PRD's story sequence maps onto the GitHub release line as follows:

| Release | Phase(s) | Status | Highlight |
|---|---|---|---|
| v0.1.0 | Phase 0–6 (S00–S16) | shipped | Shell wizard + patched-frontend image gating |
| v0.2.0 | Phase 7 (S17–S31) + wiring fixes | shipped | Tauri 2 + Svelte 5 desktop GUI, click-through works |
| v0.2.1 | Design polish (no new phase) | shipped | Zinc visual direction across all seven screens |
| v0.2.2 | **Phase 7.5 (S32 + S34) + HF1–HF3** | **planned** | macOS GUI declared stable: loop fixes the two bash/event-emission bugs, maintainer hand-fixes the three runtime-verification ones |
| v0.3.0 | **Phase 8 (Linux runtime)** | planned | Validate the GUI end-to-end on Linux (Ubuntu 22.04 / 24.04): apt deps, `host.docker.internal:host-gateway`, WebKit2GTK quirks, file-permission edges. No new screens, just runtime parity. |
| v0.4.0 | **Phase 9 (signed distributables)** | planned | Produce signed `.dmg` (macOS notarization), `.AppImage` and `.deb` (Linux), GitHub Releases automation, optional auto-update |

Phase 8 only kicks off after v0.2.2 lands and the macOS GUI is
considered the first *trustable* desktop release. Phase 9 is gated
on both macOS and Linux runtimes being stable.

---

## Notes

- The configurator never modifies files in `../../core/`, `../../chat/`,
  or `../../frontend/`. For the frontend build (S16) it either copies the
  local tree or clones from
  `https://gitlab.opencode.de/f13/microservices/frontend.git` into a temp
  directory. The original is never touched; all patching happens on the copy.
- Host Ollama on Linux: `host.docker.internal:host-gateway` requires
  Docker 20.10+ — document this in README prerequisites.
- The user's model `gemma4:31b-cloud` is used as the default suggestion
  in the Ollama flow but the list is always fetched live; no hardcoding
  the model name in templates.
- On first pass, favor correctness over cleverness. No auto-update, no
  plugin system, no telemetry. Just a reliable wizard.

## Out of Scope (for v1)

- Presets other than `core + frontend + chat`.
- RAG / summary / parser / transcription / inference services.
- Real Keycloak container + realm setup.
- Cloud LLM APIs (OpenAI, Anthropic, etc.) — can be added in v2.
- GPU compose variants.
- Windows / WSL-specific handling.
- Signed distributable GUI artifacts (`.dmg`, `.AppImage`, `.deb`) and
  any release/auto-update flow. The GUI itself is in scope (Phase 7);
  packaging *infrastructure* is in scope (S29). Producing
  signed/notarized artifacts for distribution is deferred to a future
  Phase 8 — only kicked off after the maintainer has run the GUI end
  to end on macOS and Linux locally.
- Linux GUI validation in Phase 7. The loop only exercises the Linux
  *compile* path (`cargo check` inside Docker); running the actual
  Tauri app on Linux happens in Phase 8 once the maintainer has Linux
  test cycles. Until then, the GUI is macOS-only.
