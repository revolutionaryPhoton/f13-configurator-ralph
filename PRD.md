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

- [x] **S00: Project bootstrap** ✅ shipped in v0.1.0
  Create the directory layout above. Add `.gitignore` that excludes
  `generated/` and `*.secret`. Add a minimal README.md with one-line intent
  ("Shell configurator for a minimal F13 deployment"). Write initial
  CLAUDE.md (ralph.sh already creates one, just verify it's sensible).
  First commit.

### Phase 1: UI Primitives

- [x] **S01: Colors, emoji, box-drawing helpers (`lib/ui.sh`)** ✅ shipped in v0.1.0
  Implement:
  - `ui::red`, `ui::green`, `ui::yellow`, `ui::cyan`, `ui::dim`, `ui::bold`,
    `ui::reset` — stdout escape codes. Respect `NO_COLOR` env var.
  - `ui::ok " … "`, `ui::warn " … "`, `ui::err " … "`, `ui::info " … "`,
    `ui::step "N. …"` — prefixed one-liners with emoji (✅ / ⚠️ / ❌ / ℹ️ / 🔧).
  - `ui::hr` — horizontal rule.
  - `ui::box "Title" <<< "body"` — bordered box using `╔╗╚╝═║`.
  Bats tests: invoking each helper produces a non-empty line and the right
  substring (strip ANSI when asserting).

- [x] **S02: F13 ASCII banner (`lib/banner.sh`)** ✅ shipped in v0.1.0
  `ui::banner` prints a multi-line ASCII-art "F13" logo in cyan, centered,
  followed by `   F13 · minimal configurator · v1` in dim. Use block
  characters. Must render cleanly at 80-col terminals. Bats test: banner
  prints ≥ 5 lines and contains `F13`.

- [x] **S03: Interactive prompts (`lib/prompt.sh`)** ✅ shipped in v0.1.0
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

- [x] **S04: Random secrets (`lib/secrets.sh`)** ✅ shipped in v0.1.0
  - `secret::gen [bytes]` — prints a base64url secret (default 32 bytes).
    Uses `openssl rand` if present, else `/dev/urandom` + `base64`.
  - `secret::write PATH` — generate and write with `chmod 600`.
  - Idempotent: if file exists, do not overwrite unless `--force`.
  Bats: generates unique values; file is 0600.

- [x] **S05: Port probes (`lib/ports.sh`)** ✅ shipped in v0.1.0
  - `ports::is_free PORT` — returns 0 if `lsof -iTCP:PORT -sTCP:LISTEN`
    finds nothing (or `ss -ltn` fallback on Linux).
  - `ports::pick_free PREFERRED FALLBACK_RANGE…` — returns preferred if
    free, else next free port in the range.
  Bats: `ports::is_free 1` should be 1 (privileged/likely taken).

- [x] **S06: Preflight (`lib/preflight.sh`)** ✅ shipped in v0.1.0
  `preflight::run` checks in order and prints ✅ / ❌ per check:
  1. `docker` on PATH and `docker info` succeeds.
  2. `docker compose version` prints something.
  3. bash ≥ 4.0 (check `${BASH_VERSINFO[0]}`).
  4. `curl`, `awk`, `sed`, `envsubst` on PATH.
  5. ~2 GB free on `$PWD`.
  On any failure, print an install hint and exit 1. Bats test runs with
  PATH stubs.

- [x] **S07: Host Ollama integration (`lib/ollama.sh`)** ✅ shipped in v0.1.0
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

- [x] **S08: Template renderer (`lib/render.sh`)** ✅ shipped in v0.1.0
  - `render::file SRC DEST` — runs `envsubst` on SRC with an allow-list of
    vars (no shell metachars leak into YAML).
  - `render::tree templates/ generated/` — mirrors the template dir.
  Bats: render a fixture template and diff against expected output.

- [x] **S09: Compose + config templates** ✅ shipped in v0.1.0
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

- [x] **S10: Main wizard (`bin/f13-config`)** ✅ shipped in v0.1.0
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

- [x] **S11: Launch + health wait (`lib/compose.sh`)** ✅ shipped in v0.1.0
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

- [x] **S12: Idempotency + re-run (`lib/state.sh`)** ✅ shipped in v0.1.0
  - On start, if `generated/.state` exists, read it and print the current
    config, then prompt `[k]eep existing / [e]dit (re-run wizard with
    current values as defaults) / [r]eset (delete generated/ and start
    over)`.
  - `.state` is a simple `KEY=VALUE` file written at the end of a
    successful render. Keys: `PRESET`, `CHAT_BACKEND`, `OLLAMA_MODEL`,
    `FRONTEND_PORT`, `CORE_PORT`, timestamp.
  Bats: write a fake state, assert the three paths behave correctly.

### Phase 5: Polish

- [x] **S13: Shellcheck clean-up** ✅ shipped in v0.1.0
  Run `shellcheck -S warning bin/* lib/*.sh` across the whole tree. Fix
  every warning. If a specific line truly needs an exception, add a
  narrow `# shellcheck disable=…` with a justification comment above.
  Commit.

- [x] **S14: README.md** ✅ shipped in v0.1.0
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

- [x] **S15: Demo transcript** ✅ shipped in v0.1.0
  Record a plain-text transcript of a full run (mock backend) and save
  as `docs/demo-transcript.txt`. Keep it tiny; just enough to show the
  UX. Commit.

### Phase 6: Frontend feature gating

- [x] **S16: Build a patched frontend image with feature gating** ✅ shipped in v0.1.0

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

- [x] **S17: Tauri scaffolding + dev workflow (macOS-validated)** ✅ shipped in v0.2.0

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

- [x] **S18: Engine adapter (`gui/src/lib/engine.ts`)** ✅ shipped in v0.2.0

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

- [x] **S19: Design system import (`gui/src/lib/theme/`)** ✅ shipped in v0.2.0

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

- [x] **S20: Welcome screen + state-aware routing** ✅ shipped in v0.2.0

  Invoke `/frontend-design-v2` skill before writing any UI.
  Implement `gui/src/routes/+page.svelte`:
  - F13 ASCII logo (or SVG version), tagline, primary "Begin setup" CTA.
  - "Open existing setup" link calls `engine.detectState()`. If a state
    file exists, route to `/status`. If not, the link is hidden.
  - Mockup reference: section 1 of the GUI sketch.
  Component test: with state-present and state-absent fixtures, assert
  routing.
  Commit.

- [x] **S21: Preflight screen** ✅ shipped in v0.2.0

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

- [x] **S22: Inference picker** ✅ shipped in v0.2.0

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

- [x] **S23: Ollama model picker** ✅ shipped in v0.2.0

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

- [x] **S24: Ports screen** ✅ shipped in v0.2.0

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

- [x] **S25: Build / launch pipeline** ✅ shipped in v0.2.0

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

- [x] **S26: Status screen + actions** ✅ shipped in v0.2.0

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/status/+page.svelte`:
  - Health row per service (`engine.compose.health()` polled every 5 s).
  - Primary CTA: "Open F13 in browser" (opens default browser at
    `localhost:${FRONTEND_PORT}` via `tauri://opener`).
  - Secondary actions: View logs, Stop F13, Full reset.
  - Each action streams its progress in a sticky toast.
  Mockup reference: section 6.
  Commit.

- [x] **S27: Confirmations + edge cases** ✅ shipped in v0.2.0

  Invoke `/frontend-design-v2` skill.
  - Reset confirmation modal (irreversible action — explicit "Type RESET
    to confirm" or simple double-confirm).
  - Port-collision modal with a "Pick another port" path.
  - "F13 is already running" detection on app start with a "Show status"
    or "Stop & reconfigure" choice.
  Commit.

- [x] **S28: Settings panel** ✅ shipped in v0.2.0

  Invoke `/frontend-design-v2` skill.
  Implement `gui/src/routes/settings/+page.svelte`:
  - View generated config (read-only). Copy buttons for the YAML files.
  - Edit-prompt entry point (still grey/disabled in v1 — wired to the
    "Custom system prompts" roadmap item; ships as a no-op modal that
    explains the feature is coming).
  - Theme toggle (light / dark / system).
  Commit.

- [x] **S29: Packaging infrastructure (macOS only, no distributable artifacts)** ✅ shipped in v0.2.0

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

- [x] **S30: GUI README + screenshots + CHANGELOG** ✅ shipped in v0.2.0

  - `gui/README.md`: stack, dev setup, packaging, troubleshooting.
  - Screenshots / animated GIFs of the wizard flow.
  - Top-level `README.md`: add a "GUI vs CLI" table so users know
    which surface to pick.
  - CHANGELOG.md at repo root: notes for the GUI release.
  Commit.

- [x] **S31: End-to-end smoke test (maintainer-only, not loop-runnable)** ✅ shipped in v0.2.0

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

- [x] **S32: `f13-reset` honours `F13_GENERATED_DIR`** ✅ shipped in v0.2.2 (`bba394d`)

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

- [x] **S34: Wizard's `keep` path emits per-stage events** ✅ shipped in v0.2.2 (`b192f98`)

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
the maintainer and me; each lands as a `BF [gui]` commit.

HF1 shipped in v0.2.2 alongside S32 + S34 and a chunk of UX polish.
HF2 + HF3 are still open — neither blocks normal use, so they were
deferred past v0.2.2 to a later v0.2.x patch.

- [x] **HF1: GUI uses an absolute `generatedDir`.** ✅ shipped in
  v0.2.2 across four iterations (`6510ca1` → `d2defe1` → `387699c` →
  `18cbacf`). Settled on detecting dev mode by the executable's own
  path (`target/debug/` or `target/release/`) since Tauri symlinks
  resources into the dev binary's directory and made sentinel-file
  checks unreliable. After this, GUI-launched stacks land at
  `configurator_v1/generated/` and `./bin/f13-stop` from a terminal
  Just Works without env overrides.

- [x] **HF2: Cancel button actually aborts the subprocess.**
  ✅ shipped in v0.3.2 (squash commit `69f9bff`, PR #3).
  Plumbed `AbortSignal` through `ProcessRunner.run` →
  `engine.runWizardNonInteractive` → `tauriRunner.child.kill()`.
  Run page's `handleCancel()` calls `controller.abort()` then
  tears down twice with a 1.5 s gap to catch the orphaned
  `docker compose up` grandchild (which is reparented to PID 1
  when bash dies and keeps running). The proper kernel-level
  fix (kill the process group via `setsid`/`process_group(0)`
  on the Rust side) is deferred — current double-down
  mitigation solves the user-visible bug.

- [x] **HF3: Eliminate sporadic "pull access denied" on
  `f13-frontend`.** ✅ shipped in v0.3.2 (squash commit `69f9bff`,
  PR #3). Two layers: pinned `pull_policy: never` on the frontend
  service in the compose template, and added a
  `compose::_docker_image_inspect` precondition in `compose::up`
  that returns a clear "frontend image is missing locally — re-run
  the wizard so it can rebuild" message via `COMPOSE_ERROR_MESSAGE`.
  The `--compose-up` handler propagates that into the `done` event
  so the GUI's error toast surfaces the friendly text. UX recovery
  gap (still requires walking the full Reconfigure wizard) tracked
  separately as HF5.

- [x] **HF4: Reconfigure flow doesn't actually re-render with
  the new selections.** ✅ shipped in v0.3.1 (squash commit
  `f342a1f`, PR #1). Three compounding bugs ended up being in
  scope — the original two below plus a third discovered
  during smoke testing (`F13_STATE_ACTION` was unconditionally
  cleared before `state::check` could read the env value).
  Plus a fourth UX issue: the GUI's port-check screen happens
  before the wizard runs, so the early-stop has to fire on the
  Reconfigure button click, not just inside the shell wizard.

  Original analysis preserved below for historical context.

  Two compounding bugs make the
  GUI's "Reconfigure" path silently no-op when the user
  changes the chat backend (mock ↔ Ollama) or any other
  wizard input on a running stack:

  1. **GUI side**: `runWizardNonInteractive` in
     `gui/src/lib/engine.ts` accepts a `stateAction` option
     but neither the Status screen's "Reconfigure" button
     nor `gui/src/routes/wizard/run/+page.svelte` ever sets
     it. With `.state` already on disk and no `F13_STATE_ACTION`
     in env, `state::check` defaults to `keep` —
     `bin/f13-config` then skips secrets / render / build /
     pull entirely and only re-runs `compose::up` against the
     unchanged compose file. The user's new backend choice is
     never written to disk.

  2. **Shell side**: even if the GUI passed
     `stateAction: "edit"`, `state::read` in `lib/state.sh`
     unconditionally clobbers env-set values (`PRESET`,
     `CHAT_BACKEND`, `OLLAMA_MODEL`, `FRONTEND_PORT`,
     `CORE_PORT`) with the saved state. So
     `F13_CHAT_BACKEND=ollama` from the GUI survives only
     until `state::read` overwrites it with the previously
     saved `mock`. The CLI's interactive `edit` flow needs
     state values as defaults, but the GUI needs the env to
     win.

  **Fix sketch:**
  - Status "Reconfigure" → wizard run page passes
    `stateAction: "edit"` to `runWizardNonInteractive`. (Or
    derive it from "is the new selection different from the
    saved state?" — but a static `edit` is the simpler call.)
  - `state::read` only assigns from the state file when the
    target var is unset/empty in the current env. Bats
    coverage: pre-set `CHAT_BACKEND=ollama`, point at a
    fixture state file with `CHAT_BACKEND=mock`, assert the
    var stays `ollama`.

  **Hand-verifiable:** start F13 with mock → click
  Reconfigure → switch to Ollama → finish wizard. The chat
  service in `docker compose ps` should now point at the
  upstream chat image with `CHAT_BACKEND=ollama` env, and
  `cat generated/.state` should show the new backend.
  Reverse direction (Ollama → mock) likewise. Cannot be
  fully automated since the GUI's reconfigure flow needs a
  real running stack to exercise.

  **Likely-others note.** The reconfigure path probably has
  more edge cases that this single bug is masking: e.g. if
  the user changes ports during reconfigure, does the
  compose `restart: unless-stopped` semantic produce the
  expected port swap? Does Ollama → mock leave a stale
  `OLLAMA_MODEL` in `.state` that confuses the next edit?
  Once HF4's two layers are fixed and the wizard actually
  re-renders, sweep the reconfigure flow for adjacent
  surprises before declaring it done. The maintainer's wish
  here is "in-flight (or near-instant) model/backend swaps
  for a running F13 stack" — HF4 is the unblocker for that
  larger goal.

- [ ] **HF5: Auto-regenerate broken stack on Start.** Promoted
  from a maintainer hand-fix to a planned story — now tracked
  as **S61 in Phase 11** (target v0.6.0). The discovery context
  is preserved in S61's body. This bullet stays here as a
  cross-reference so anyone scanning the maintainer-hand-fixes
  section after HF4 doesn't think the trail ends at HF4.

### Phase 8: Linux runtime parity (no new screens)

Goal: validate the existing Phase 7 / 7.5 GUI end-to-end on Linux
with no visual changes — runtime parity only. The GUI works on
the maintainer's macOS box; this phase makes it work for a Linux
user the same way.

Mandatory rules unchanged from Phase 7. Backpressure stays
headless. No new Svelte UI; this is plumbing.

> **Status (v0.3.0):** S37–S40 shipped via interactive
> maintainer sessions on a real WSL2 Ubuntu 22.04 box. The
> ralph loop did NOT drive these; the bugs were diagnostic-
> heavy and benefited from a hand-on-keyboard back-and-forth
> with a running app. The GUI is now mostly stable on Linux
> for daily local use — first-time setup, Stop/Start cycles,
> reset, mock and host-Ollama (including cloud-tagged
> models) all work end-to-end. Loose ends remain (HF4 below,
> plus likely a few neighbours of it that surface once HF4 is
> fixed); none block normal use. Re-running the loop on these
> stories is not necessary.

- [x] **S37: WebKit2GTK + apt prerequisites doc** ✅ shipped in v0.3.0

  Document and validate the apt list needed to run the existing
  Tauri 2 + Svelte 5 GUI on Ubuntu 22.04 and 24.04. Currently
  `gui/CONTRIBUTING.md` lists the *compile* deps (libwebkit2gtk-
  4.1-dev etc.) for `cargo check` inside Docker — Phase 8 adds
  the *runtime* deps and tests `tauri dev` on a real Ubuntu box.
  Note any WebKit2GTK rendering quirks the existing screens hit
  (font metrics, animation easing, scrollbar styling).

  **Known quirks (WSL2 + Ubuntu).** Three macOS-free-lunch
  items that have to be installed or worked around explicitly,
  documented in `gui/CONTRIBUTING.md`:

  1. **libEGL `/dev/dri/*` probe failures.** WebKit2GTK and Mesa
     probe the DRI nodes on startup; on WSL2 they are
     `root:root 0600` (the real GPU bridge is `/dev/dxg`), so
     `libEGL warning: failed to open …` spams stderr while
     Mesa falls back to software rendering. The runtime forces
     the software path explicitly via
     `apply_linux_runtime_defaults()` in
     `src-tauri/src/lib.rs`: `LIBGL_ALWAYS_SOFTWARE=1`,
     `WEBKIT_DISABLE_DMABUF_RENDERER=1`,
     `WEBKIT_DISABLE_COMPOSITING_MODE=1`. Each is only set
     when the user hasn't already exported it.

  2. **Color-emoji font missing.** Emoji glyphs (🧪 🦙 …) used
     across the wizard render as missing-glyph boxes without
     `fonts-noto-color-emoji` installed. apt prereq, no code
     fix.

  3. **`xdg-open` no-op on WSL2.** The Status screen's "Open
     F13 in browser" button calls `tauri-plugin-opener` which
     on Linux invokes `xdg-open`. WSL2 has no graphical
     browser registered by default — `wslu` (apt) provides
     `wslview` to route `xdg-open` through to the Windows-side
     default browser. apt prereq, no code fix.

- [x] **S38: `host.docker.internal` on Linux** ✅ shipped in v0.3.0

  Confirmed working under WSL2 Ubuntu 22.04 + Docker Desktop
  for both mock and Ollama backends — the
  `extra_hosts: host.docker.internal:host-gateway` line that
  the compose template already injects does the right thing.
  No code change required. The proposed preflight warning for
  ancient Docker daemons (<20.10, missing `host-gateway`) was
  not added: 20.10 was released 2020-12 and the existing
  `docker compose` preflight already trips on installs that
  old, so the warning would be redundant.

- [x] **S39: File-permission edges** ✅ shipped in v0.3.0

  macOS file ops are forgiving; Linux exposes things macOS
  silently fixes. Audit:
  - `secret::write` ships with chmod 644 (was 600). The `core`
    image runs as uid 999, gid 0, and on Linux bind-mounts
    preserve real UIDs — so 0600 files owned by the host user
    were unreadable inside the container, manifesting as
    `PermissionError: [Errno 13] Permission denied:
    '/core/secrets/feedback_db.secret'` on `core` startup.
    Docker Desktop on macOS papers over this with its userspace
    bind-mount shim, which is why the bug only surfaced under
    WSL2 / native Linux. The 0644 mode is uniform across both
    OSes; host-side gating is provided by the parent
    `generated/` directory living inside `$HOME`. Same fix
    applied to the inline `chmod 600` on `feedback_db.secret`
    in `bin/f13-config` (which bypasses `secret::write`).
    `lib/state.sh`'s `chmod 600` on `.state` is unchanged —
    that file is host-only, never bind-mounted.
  - `compose:up` mounts: confirm UID/GID alignment between the
    host user and the postgres / core containers' expected user.
  - The Tauri-spawned bash subprocess inherits a sane PATH /
    HOME / TMPDIR on Linux launches.

- [x] **S40: Linux smoke pass** ✅ shipped in v0.3.0

  Maintainer ran the full wizard happy-path manually on WSL2
  Ubuntu 22.04 (mock backend, default ports, edit cycle, Stop
  / Start, full reset). Every documented flow worked. Small
  Svelte/runtime fixes that landed during the pass:
  - `BF [secrets]` 0644 file mode for bind-mount readability
    on Linux (S39 driver).
  - `BF [gui]` `apply_linux_runtime_defaults()` silences libEGL
    `/dev/dri/*` warnings + WebKit DMA-BUF / compositor
    fallback (S37 driver).
  - `BF [gui]` Tailwind v4 + `<script lang="ts">` interaction
    in `ProgressBar.svelte` — keyframe hoisted to global CSS
    so the file has no `<style>` block for Tailwind to
    misparse (orthogonal but surfaced during Linux bringup).
  - `BF [wizard]` `edit` reuses the existing
    `feedback_db.secret` so the postgres volume + new secret
    stay aligned across re-runs.
  - Plus image-pin hygiene (chat v1.2.0, core v2.0.0,
    postgres 17, frontend git tag v2.0.0) and a
    `f13-frontend:v2.0.0_based` rename so the local image
    name reflects the upstream ref.

  Per-screen Linux screenshots for `gui/README.md` were not
  captured — deferred to whenever the maintainer has time;
  the macOS ones still represent the visual surface
  faithfully (Linux runs through the same WebKit2GTK and
  the same design tokens).

  Known loose end: HF4 (reconfigure-flow no-op on backend
  swap) was discovered during this pass; it doesn't block
  normal use but is the unblocker for "near-instant model
  swaps for a running F13 stack" — see Maintainer hand-fixes
  above.

### Phase 9: GUI localization + zoom (no shell wizard changes)

Two user-visible polish features that don't touch the shell
wizard. **Target release: v0.4.0.** Designed to be ralph-loop
driven — at least two of the stories below are mechanical
enough that the loop can land them per its usual iteration
cadence; the zoom story is research-first and may need
maintainer judgement after the loop posts its findings.

Mandatory rules unchanged from Phase 7. Backpressure stays
headless (`cd gui && npm run check && npm run test:unit &&
cargo check` + the original shellcheck/bats for any shell-side
changes — which should be zero for this phase). All stories
land on a single feature branch (`feat/phase9-i18n-zoom`); the
loop commits per story; a single Phase 9 PR rolls them up for
maintainer review before merge.

**Scope boundaries:**
- GUI only. The shell wizard's terminal output stays English
  — that's the documented operator surface and translating it
  has a different audience profile (ops, CI, headless).
- Locale picker is visible **only on the welcome / startup
  screen**, not in the Settings panel or anywhere else
  mid-flow. Once chosen, persisted to localStorage and never
  re-prompted. Rationale: users pick once on first run; a
  per-screen language switcher would be busywork and dilute
  the picker's discoverability where it matters.
- English is the canonical message source. Translators (de,
  fr, es) translate from English; all message keys live in
  the en catalog first; missing keys in a translation catalog
  fall back to English at runtime.

- [x] **S41: i18n infrastructure + English baseline** ✅ shipped in v0.4.0 (squash commit `dc3d10f`, PR #4)

  Pick an i18n library compatible with Tauri 2 + SvelteKit
  static-adapter + Svelte 5 runes. Candidates: `svelte-i18n`,
  `@inlang/paraglide-js`, or a hand-rolled `$state`-backed
  store reading JSON catalogs. Loop should briefly evaluate
  trade-offs in the commit body, then pick one.

  Deliverables:
  - Catalog format chosen and one English catalog
    (`gui/src/lib/i18n/en.json` or equivalent) seeded with
    every user-visible string in the GUI today. Inventory the
    strings by grepping `.svelte` files; hardcoded strings
    become `t("welcome.title")` (or whichever API the chosen
    library exposes).
  - Locale-aware store / context that components consume
    without per-component bootstrapping.
  - `LOCALE` defaults to English. No picker yet — that's S42.
  - Existing tests stay green; updated where they grep
    hardcoded strings that are now translation keys.

  **Backpressure:** `npm run check && npm run test:unit &&
  cargo check` clean. Coverage on the new i18n module ≥ 75%.

- [x] **S42: Locale picker on welcome screen + persistence** ✅ shipped in v0.4.0

  Add a locale picker to the welcome screen. UI shape: small
  dropdown or four-button row (EN / DE / FR / ES) in a
  non-intrusive position (header corner or below the kicker).
  Choosing a locale:
  - Persists to `localStorage` under
    `f13.configurator.locale`.
  - Updates the i18n store immediately so subsequent screens
    render in the new language.
  - **Does NOT appear anywhere else** — not in Settings, not
    in the status hero, not in error toasts. Welcome-screen
    only.

  Default behaviour:
  - First run, no stored locale: default to English. (Don't
    auto-detect system locale for v0.4.0 — keeps the surface
    predictable.)
  - Stored locale present: load it before the welcome screen
    renders so the user never sees an English flash on
    return visits.

  **Backpressure:** vitest assertions covering: picker
  renders four options, click persists to localStorage,
  stored value survives reload (simulated), absent
  localStorage falls back to English.

- [x] **S43: German, French, Spanish translations** ✅ shipped in v0.4.0

  Translate the entire English catalog from S41 into `de.json`,
  `fr.json`, `es.json`. This is the mechanical pass — the loop
  can do straightforward translation. Maintainer reviews the
  output for cultural / register issues before the Phase 9 PR
  merges.

  Constraints:
  - Match the English message-id surface exactly (no missing
    keys, no extras). A test fixture should iterate
    `Object.keys(en)` and assert each is present in de/fr/es;
    a missing translation should fail the test, not silently
    fall back.
  - For F13-specific brand terms (`F13`, `Ollama`, `Docker`,
    `mock`, `compose`, etc.) keep the English spelling. Don't
    translate proper nouns.
  - Tone: neutral, instructive (matching the existing English
    copy). Formal "Sie" for German; "vous" for French; "usted"
    or neutral infinitive for Spanish — pick what feels right
    in context.

  **Backpressure:** vitest covers key-parity across all four
  locales. No additional UI tests needed; switching the locale
  in vitest and asserting a known phrase renders in the
  expected language is enough.

- [x] **S44: Zoom — research, then implementation** ✅ shipped in v0.4.0 (CSS-zoom approach across all three Tauri webview backends)

  The GUI currently has no way for users to zoom in, and on
  high-DPI laptops the text can feel cramped. Implement zoom.

  **Step 1 — research** (loop commits a `gui/ZOOM-NOTES.md`
  or includes the analysis in the implementation commit body):

  Does Tauri 2 propagate the OS-level zoom shortcuts
  (`Ctrl/Cmd + +/-/0`) to the webview? Check each platform:
  - macOS: WKWebView default; does it work out of the box, or
    does Tauri intercept the shortcuts?
  - Windows: WebView2; similar question.
  - Linux: WebKitGTK; similar question.

  If shortcuts don't work natively, the alternatives are:
  - **Webview-API approach**: call platform-specific APIs from
    Rust to set zoom factor (WKWebView `setMagnification`,
    WebView2 `ZoomFactor`, WebKitGTK `set_zoom_level`). Expose
    via a Tauri command that the frontend invokes.
  - **CSS-zoom approach**: scale the root via CSS
    `transform: scale()` or `zoom:` property; track factor in
    a Svelte store. Simpler but accessibility-suspect (screen
    readers may misreport, focus rings may blur).

  **Step 2 — implementation** (the chosen approach):

  Provide both: keyboard shortcuts (`Ctrl/Cmd + +/-/0` — `+`
  zooms in, `-` zooms out, `0` resets) AND a small zoom
  control in the header / Settings panel (whichever fits the
  existing chrome better — loop decides). Persist the zoom
  factor to `localStorage` under `f13.configurator.zoom` so
  it survives restart. Clamp to a reasonable range (e.g.
  0.6x – 2.0x).

  **Hand-verifiable:** zoom in/out via shortcut and via UI
  control on macOS; text scales smoothly; reset returns to
  100%; zoom factor persists across app restart. Linux
  parity verified in a follow-up session.

  **Backpressure:** vitest on the store + clamp logic; a
  smoke test of the keyboard handler (jsdom-friendly).

---

> **Status:** all stories `[ ]` — feature branch
> `feat/phase9-i18n-zoom` will be created by the loop on
> first iteration; a Phase 9 PR opens once S41 lands and
> accumulates the rest as commits.

### Phase 10: Signed distributables + bundled-mode data paths

Two intertwined deliverables: produce the actual installer
artifacts AND fix the dev-only path assumptions baked into HF1.
**Target release: v0.5.0.**

The current GUI uses `dev_workspace_root() / "generated"`
(== `configurator_v1/generated/`) as its data path. That only
works in a dev checkout — bundled `.app` / `.AppImage` /
`.deb` installs have no such tree. Phase 10 swaps the bundled
branch over to the OS-canonical user-data location and teaches
`f13-stop` / `f13-reset` to discover it.

Previously numbered Phase 9 — bumped to Phase 10 in v0.3.2 to
make room for the new i18n + zoom Phase 9 (shipped v0.4.0).

> **Mixed loop / maintainer phase.** S51 and S52 are pure code
> and loop-runnable; the loop can land them as soon as PROGRESS.md
> queues them. S53–S56 are maintainer-driven because they need
> signing certificates and GitHub release secrets the headless
> loop container can't have. The auto-update story (formerly S57)
> moved to Phase 11 to keep this phase focused on first-distribution.

**Target architectures (decided 2026-05-14):**
- macOS: **arm64 only** (Apple Silicon). No universal binary —
  the size cost isn't worth it for the small Intel-Mac audience
  at this point.
- Linux: **x86_64 only**. arm64 Linux desktop is rare enough
  that it's not worth the matrix expansion.
- Distribution channel: **GitHub Releases only** for v0.5.0.
  Homebrew cask is scoped to Phase 12.

**Branch + PR workflow:** all Phase 10 work lands on a single
feature branch `feat/phase10-distributables`. Stories commit
onto it incrementally; a single Phase 10 PR rolls everything up
for maintainer review before merging to `main` and tagging
v0.5.0.

- [ ] **S51: `appLocalDataDir` for bundled installs**

  - Rust: `get_generated_dir()`'s bundled branch returns
    `app.path().app_local_data_dir().join("generated")`.
    macOS: `~/Library/Application Support/de.f13-os.configurator/generated/`.
    Linux: `~/.local/share/de.f13-os.configurator/generated/`.
    Dev branch unchanged (still `configurator_v1/generated/`).
  - Same treatment for `get_bin_dir()` — bundled returns
    `resource_dir/bin`, dev returns `configurator_v1/bin`.
  - Sidecar resources (`bin/`, `lib/`, `templates/`) bundled via
    Tauri's `resources` config (already in place from S29).

  **Loop-runnable.** Pure Rust + tauri.conf.json change. Existing
  vitest + cargo check backpressure covers it.

- [ ] **S52: Discovery in `f13-stop` / `f13-reset`**

  Today the shell scripts only look at their own `${SCRIPT_DIR}/
  ../generated`. Extend with:
  1. `${F13_GENERATED_DIR}` env override (already honoured).
  2. Auto-discover from a known list of locations:
     - `${F13_GENERATED_DIR}` if set
     - `${SCRIPT_DIR}/../generated` (CLI-created stack)
     - `~/Library/Application Support/de.f13-os.configurator/generated`
     - `~/.local/share/de.f13-os.configurator/generated`
  3. Pick the first path containing a `docker-compose.yml`.
  4. If multiple match, error and require explicit
     `--gen-dir <path>` or env override.

  Bats tests for each branch. **Loop-runnable.**

- [ ] **S53: Code signing (macOS arm64)**

  - Apple Developer ID Application certificate (maintainer holds
    the cert in their keychain; CI receives a base64-encoded .p12
    via `MACOS_CERTIFICATE` repo secret).
  - `tauri.conf.json bundle.macOS.signingIdentity` set to the
    Team-ID-qualified cert name.
  - Notarization via `xcrun notarytool` with an app-specific
    password (repo secrets: `APPLE_ID`, `APPLE_PASSWORD`,
    `APPLE_TEAM_ID`).
  - Document the maintainer setup in `gui/SIGNING.md`
    (gitignored — has cert names + workflow but no secrets).

  **Maintainer-driven.** Cert + secrets are not available to the
  loop. macOS-only build target: `aarch64-apple-darwin`.

- [ ] **S54: `.dmg` production (arm64)**

  Set `bundle.targets` to `["dmg"]` for the macOS profile. Signed
  + notarized output, single-architecture `aarch64-apple-darwin`.
  Smoke test on a clean Apple Silicon Mac (no developer tools
  installed) to confirm Gatekeeper accepts it. Document the
  install flow in README's "Quickstart" with a download link.

  **Maintainer-driven.** Depends on S53.

- [ ] **S55: `.AppImage` and `.deb` production (x86_64)**

  - AppImage tooling (linuxdeploy + appimagetool).
  - Debian control metadata (postinst / postrm scripts that
    register `de.f13-os.configurator` desktop file).
  - Single architecture: `x86_64-unknown-linux-gnu`. No arm64
    Linux builds for v0.5.0.
  - Smoke test on Ubuntu 22.04 + 24.04.
  - Document in README.
  - Optional: GPG-sign artifacts if maintainer provides a key.

  **Maintainer-driven** (or loop-runnable for the workflow YAML;
  signing/smoke-testing stays maintainer-side).

- [ ] **S56: GitHub Releases automation**

  - `.github/workflows/release.yml`: on tag push (`v*`), build
    `.dmg` on `macos-latest` (arm64 target) + `.AppImage` / `.deb`
    on `ubuntu-latest` (x86_64), sign / notarize, attach to a
    **draft** Release.
  - Maintainer reviews + publishes the Release manually
    (no auto-publish). This matches the manual-publish convention
    established in v0.3.x.

  **Maintainer-driven** to wire up the secrets; the workflow YAML
  itself can be drafted by the loop once secrets are configured.

### Phase 11: UX polish + auto-update

Two stories that pair well thematically — both are post-distribution
polish that smooths over rough edges Phase 10 leaves behind. **Target
release: v0.6.0.**

S61 is the former HF5 ("auto-regenerate broken stack on Start"),
promoted from a maintainer hand-fix to a proper loop-runnable story
since it's pure GUI plumbing. S62 is the former S57, deferred from
Phase 10 to keep that release focused on first-distribution.

**Branch + PR workflow:** single feature branch
`feat/phase11-polish-autoupdate`, single Phase 11 PR.

- [ ] **S61: Auto-regenerate broken stack on Start**

  Originally tracked as HF5. When the Start action fails because of
  a fixable precondition (today: the locally built frontend image is
  missing, surfaced by HF3's `compose::up` precondition; tomorrow:
  any other build-step-recoverable error), the user should not have
  to walk the full Reconfigure wizard (preflight → inference →
  ollama → ports → run) just to rebuild. `.state` already has every
  selection needed.

  **Fix sketch:**
  - When the GUI's Start action surfaces a frontend-image-missing
    error (detect via the `COMPOSE_ERROR_MESSAGE` content shipped
    in v0.3.2), offer a single "Rebuild and start" button on
    `/status`.
  - That button re-runs `runWizardNonInteractive` with
    `stateAction: "edit"` and the existing `.state` values,
    skipping all wizard prompts — same plumbing as HF4 but
    invoked automatically.
  - Optionally: detect the precondition proactively on `/status`
    load so the user sees a "Rebuild needed" banner before clicking
    Start.

  **Hand-verifiable:** with F13 stopped, `docker image rm
  f13-frontend:v2.0.0_based`; Start button on `/status` should
  surface "Rebuild and start" (or transition to it after a failed
  Start), single click should rebuild and bring the stack up
  without any wizard navigation.

  **Loop-runnable.** Pure GUI plumbing.

- [ ] **S62: Optional auto-update (Tauri updater)**

  Tauri's updater plugin — opt-in via a settings toggle. Update
  manifest hosted in the GitHub Release (signed with a separate
  Tauri updater key, distinct from the Apple Developer ID cert).

  **Maintainer-driven.** Requires:
  - `tauri signer generate` to produce the updater keypair.
  - `TAURI_PRIVATE_KEY` + `TAURI_KEY_PASSWORD` repo secrets for CI.
  - Public key embedded in `tauri.conf.json` (committed).
  - Update workflow appended to `.github/workflows/release.yml`
    (signs the manifest, attaches to the Release as `latest.json`).
  - Settings UI toggle (loop-runnable once the plumbing exists).

  Can slip to a v0.6.x patch if it proves more complex than the
  rest of Phase 11 combined.

### Phase 12: Homebrew distribution

A single-purpose phase: make `brew install --cask f13-configurator`
work for macOS users. **Target release: v0.7.0.**

GitHub Releases stay the canonical artifact source; Homebrew is a
convenience layer on top. Requires a Homebrew tap repository
(`homebrew-f13` or similar under the maintainer's account), a cask
formula referencing the GitHub Release `.dmg`, and documentation.

**Branch + PR workflow:** single feature branch
`feat/phase12-homebrew`, single Phase 12 PR.

- [ ] **S71: Create Homebrew tap + cask formula**

  - New repository: `revolutionaryPhoton/homebrew-f13` (or chosen
    org name).
  - `Casks/f13-configurator.rb` referencing the latest GitHub
    Release `.dmg` URL + SHA-256 + version.
  - `brew tap revolutionaryPhoton/f13 && brew install --cask
    f13-configurator` should install the app to `/Applications/`.

  **Maintainer-driven.** Needs the tap repo created and seeded.

- [ ] **S72: README install path**

  Document the Homebrew install command in the root README's
  Quickstart for macOS, alongside the direct `.dmg` download
  link. Keep the `.dmg` download as the primary path; Homebrew
  is an alternative.

  **Loop-runnable** once the tap repo exists.

- [ ] **S73: Release-workflow integration (optional)**

  Extend `.github/workflows/release.yml` to bump the cask
  formula in the tap repo automatically on each GitHub Release.
  Needs a fine-grained PAT scoped to the tap repo (repo secret
  `HOMEBREW_TAP_TOKEN`). Manual bump is fine for v0.7.0; this
  story is optional.

  **Maintainer-driven** for the PAT; YAML is loop-draftable.

> **Future channels (not scoped):** Snap, Flatpak, Microsoft Store,
> the Mac App Store — all would require additional ceremony
> (sandboxing, store review, etc.). GitHub Releases + Homebrew
> covers ~90% of the realistic install paths for this kind of
> developer tool.

### Phase 13: Full preset — RAG + summary + parser

Today the configurator ships exactly one preset: `core + frontend +
chat`. That's the easiest possible slice of F13 — useful for trying
the platform but nowhere near what real users want. Phase 13 adds a
**`full`** preset that brings up the rest of F13's microservice
catalog as a single opinionated bundle. **Target release: v0.8.0.**

No per-service customization in this phase — that's Phase 14. Phase
13 deliberately keeps the UX simple ("basic" vs "full" radio) while
the templates, health-wait logic, dependency graph, and resource
estimation are all proven against a working stack.

**Out of scope for this phase:**
- Transcription (Whisper / similar) — defer to a future "specialty
  services" phase when there's user demand.
- Per-service toggles — Phase 14.
- Custom system prompts / chat parameters — Phase 15.
- Frontend branding overrides — Phase 16.

**Branch + PR workflow:** single feature branch
`feat/phase13-full-preset`, single Phase 13 PR.

- [ ] **S81: F13 microservice catalog research**

  Document upstream F13 RAG / summary / parser services in
  enough detail to template them: image pins (current versions),
  env-var contracts, exposed ports, health endpoints, inter-
  service dependencies. Known dependencies as of 2026-05:
  - **RAG → embedding model** (Ollama path) — RAG cannot run
    without an embedding model available to its retrieval
    layer. Independent of parser.
  - **Summary → parser** — summary doesn't work without parser
    upstream of it; parser is mandatory whenever summary is
    enabled. Independent of RAG.
  - **Parser alone is valid** — has its own API even if
    summary is the main consumer.

  Output: a new `docs/services-catalog.md` in the configurator
  repo (or a section in the README). Each service gets a row
  with image, port(s), env vars, depends-on, RAM estimate.

  **Maintainer-driven** for the upstream coordination + image-
  pin decisions. The loop can draft the markdown skeleton from
  public F13 sources but the maintainer signs off on what's
  current and supported.

- [ ] **S82: RAG service + embedding-model handling**

  Add the RAG service to `templates/docker-compose.yml.tmpl`
  under a `full` Compose profile. Wire its env vars from `.env`
  (`RAG_*` namespace). Add a health-wait step in `lib/compose.sh`.

  Ollama picker grows a second model selection — **embedding
  model** (default `nomic-embed-text`) — that only shows when
  RAG is in the selected preset. Phase 9 already added the
  embedding-model *warning* on the chat picker; this phase adds
  an embedding-model *picker* for the RAG path. Free-text input
  supported (same UX as the chat-model picker), since users may
  prefer specific embedding models.

  ENABLED_FEATURES env var grows from `chat` to `chat,rag` when
  RAG is in the preset.

  **Loop-runnable** for the template + plumbing; maintainer
  validates against a real RAG-ready Ollama install.

- [ ] **S83: Summary service**

  Add the summary service to the `full` Compose profile. Wire
  its env vars. Health-wait. ENABLED_FEATURES grows to include
  `summary`. **Summary requires parser** — enable parser
  whenever summary is in the selection. In Phase 13's
  basic/full radio this is automatic (both are in `full`);
  Phase 14's checkbox UI will need explicit dependency
  enforcement.

  **Loop-runnable.** No new model picker.

- [ ] **S84: Parser service**

  Add the parser service to the `full` Compose profile. Wire
  env vars. Health-wait. ENABLED_FEATURES grows to include
  `parser`. Parser is upstream of summary (provides the document
  extraction that summary consumes) but has its own API and is
  valid as a standalone service — no warning needed if parser is
  enabled without summary. The reverse (summary without parser)
  is a hard dependency enforced in S83/S93.

  **Loop-runnable.**

- [ ] **S85: Preflight resource estimation**

  Today `preflight::run` checks ~2 GB free disk. The full
  preset can easily need 15–30 GB RAM and 10+ GB disk
  depending on the chat-model + embedding-model sizes. Extend
  preflight with:
  - Per-service RAM estimate (sum across selected services
    using the catalog data from S81).
  - Per-model RAM estimate based on the chat-model size
    (cloud-tagged = 0 local, locally-pulled = derive from
    `ollama list` or a known-models table).
  - Compare against `sysctl hw.memsize` (macOS) / `/proc/meminfo`
    (Linux). Warn (not block) if estimate > available.
  - Disk estimate vs `df` output.

  Bats tests for the math; manual verification for the
  platform-specific RAM probes.

  **Loop-runnable.**

- [ ] **S86: Preset picker (shell + GUI)**

  - Shell wizard: a new step (between the inference picker and
    the Ollama-model picker) — "Which F13 services?" — with two
    radio options: `basic` (core+frontend+chat, today's
    default) and `full` (everything from S82–S84).
  - GUI: a new screen between `/wizard/inference` and
    `/wizard/inference/ollama` showing the two presets as
    Tile components (like the inference picker), with bullet
    points listing what each preset includes and the rough
    resource estimate from S85.
  - State: `.state` grows a `PRESET` key (already there
    nominally — currently always `core+frontend+chat`) with
    legal values `basic` / `full`.
  - i18n: add catalog entries for `preset.*` keys in all four
    locales (Phase 9 i18n infrastructure handles it).

  Updates the breadcrumb from "Step N of 4" to "Step N of 5"
  in the relevant screens.

  **Loop-runnable.**

### Phase 14: User-adjustable microservice set

Phase 13 ships an opinionated bundle. Phase 14 replaces the
`basic`/`full` radio with a **checkbox grid** so users can mix and
match. **Target release: v0.9.0.**

This is purely a UX layer on top of Phase 13's templates and
preflight machinery — no new service work, no new image pins.
Smaller phase, ~4 stories.

**Branch + PR workflow:** single feature branch
`feat/phase14-adjustable-services`, single Phase 14 PR.

- [ ] **S91: Multi-select picker (shell + GUI)**

  Replace the basic/full radio from S86 with a checkbox grid:
  one row per service (chat, RAG, summary, parser), each with
  a description, RAM estimate, and dependency arrows ("RAG
  needs embeddings"). Chat is always required (greyed out,
  pre-checked).

  `.state.PRESET` becomes a comma-separated list (e.g.
  `chat,rag` or `chat,rag,summary,parser`).

  **Loop-runnable.**

- [ ] **S92: Live resource estimation**

  As the user toggles checkboxes, the "estimated RAM / disk"
  number updates in real time (no full preflight re-run, just
  recompute the math from S85). Visual cue when the estimate
  exceeds available host resources.

  **Loop-runnable.**

- [ ] **S93: Dependency enforcement**

  - If user enables RAG, auto-tick "embedding model required"
    on the Ollama path (or surface a warning on the mock path
    since RAG with mock doesn't make sense).
  - If user enables summary, auto-tick parser (hard dependency)
    and surface an info note explaining why. Block continue if
    summary is selected but parser is somehow unticked.
  - Parser without summary is fine — no warning. Parser has its
    own API.
  - If user disables chat (which shouldn't be possible per S91,
    but defensive), block continue.

  Bats + vitest cover the dependency graph evaluator.

  **Loop-runnable.**

- [ ] **S94: COMPOSE_PROFILES + ENABLED_FEATURES generation**

  The compose template grows multiple profiles (`chat`,
  `rag`, `summary`, `parser` — each guarding its service
  block). `COMPOSE_PROFILES` in `.env` becomes the
  comma-separated activation list; `ENABLED_FEATURES` (the
  frontend gating var) becomes the parallel list. Both are
  derived from `.state.PRESET`.

  Render tests verify the right services are in the rendered
  `docker-compose.yml` for each preset combination. Integration
  tests would need real containers — out of scope for the loop,
  maintainer smoke-tests representative combos (chat-only,
  chat+rag, full set, parser-without-rag-warned).

  **Loop-runnable.**

### Phase 15: Chat parameter tuning

User-facing tuning of the chat experience: system prompt, model
temperature, maximum input tokens, maximum output tokens. **Target
release: v0.10.0.**

No new services, no upstream coordination — just exposing
configuration that the chat service already supports. Smallest
post-distribution phase.

**Branch + PR workflow:** single feature branch
`feat/phase15-chat-params`, single Phase 15 PR.

- [ ] **S101: Chat config template extension**

  Extend `templates/chat/llm_models.yml.tmpl` with the
  parameters the upstream chat service actually accepts:
  `system_prompt`, `temperature`, `max_input_tokens`,
  `max_output_tokens` (subject to S81's research catalog —
  the actual list comes from F13's chat service docs).

  Defaults sensible enough that users who never visit the
  settings panel get the same behaviour as today. `.state`
  grows matching keys.

  **Loop-runnable.**

- [ ] **S102: Settings panel UI (shell + GUI)**

  - GUI: a new "Chat" section in Settings (`/settings`)
    alongside the existing "Appearance" and "Generated config"
    sections. Form fields for each parameter, save-on-change
    (no separate save button — auto-persist to `.state` and
    write through to the rendered chat config). Trigger a
    chat-service restart on save (via the existing
    `compose.up` / `compose.restart` path).
  - Shell wizard: a new "Chat parameters" step (optional —
    skippable with defaults) between the model picker and
    the ports screen. Or a `--edit-chat-params` CLI flag for
    standalone access without re-running the full wizard.
  - i18n: catalog entries for `settings.chat.*`.

  **Loop-runnable.**

- [ ] **S103: Persistence + reload + smoke**

  `.state` survives wizard re-runs (existing HF4 plumbing
  handles this). Verify by switching values, restarting F13,
  and checking the chat service picks them up. Add a vitest
  for the GUI form + bats for the shell flow.

  **Loop-runnable** for the wiring; maintainer smoke-tests
  against a real chat service.

### Phase 16: Branding / text customization

The biggest customization story — let organizations rebrand F13 for
their own use. Logo, color palette, and arbitrary text-string
overrides. **Target release: v0.11.0.**

**Architecture constraint:** F13 frontend does NOT support runtime
overrides (no env-var or volume-mount mechanism, and no upstream
appetite for adding one as of 2026-05). The only viable path is
**extending the existing S16 patched-build pattern** — generate
overrides into the patched frontend image at build time, same as
`UIStore.js` and the `docker-entrypoint.sh` patches already do.

That means:
- Every branding change triggers a frontend rebuild (~1–3 min).
- Patches are tightly coupled to F13 frontend internals; pinning to
  a specific frontend version (already in place since v0.3.0) becomes
  even more important.
- A new frontend release may break the patches; bump-and-test cycle
  needed when `_FRONTEND_GIT_REF` changes.

**Branch + PR workflow:** single feature branch
`feat/phase16-branding`, single Phase 16 PR.

- [ ] **S111: Patchable-surface inventory**

  Survey the F13 frontend (at the currently pinned `_FRONTEND_GIT_REF`
  tag) for:
  - Hardcoded logo references (file paths + sizes)
  - Color tokens (CSS variables, Tailwind config, inline styles)
  - Hardcoded German strings (i18n catalog files? hardcoded JSX?)
  - Favicon
  - Page title / metadata

  Output: `docs/branding-surfaces.md` listing each surface, its
  location in the frontend source, and the patch approach.

  **Maintainer-driven research** — needs eyes on the upstream
  frontend source.

- [ ] **S112: Logo + favicon override**

  - Configurator accepts user-supplied image files (logo .svg or
    .png, favicon .ico or .png).
  - `frontend::patch_and_build` extends to copy these into the
    appropriate frontend assets directory before `docker build`.
  - Wizard step / Settings panel UI for upload.
  - `.state` stores paths (or copies into `generated/branding/`).

  **Loop-runnable** for the wiring; maintainer validates the
  rebuild produces a working image.

- [ ] **S113: Color palette override**

  - Accept user colors (primary, secondary, accent, etc. — the
    exact palette comes from S111's inventory).
  - Patch the frontend's CSS variables (or Tailwind theme config)
    at build time.
  - Wizard step / Settings panel with color pickers and a live
    preview component.

  **Loop-runnable** for the patch logic; tricky for the live
  preview if it requires running the patched frontend in a
  preview iframe — may need a separate preview-only build target.

- [ ] **S114: Text string override**

  - Accept a key:value JSON (`{"app.title": "Bürgerassistent",
    ...}`) from the user.
  - Patch the frontend's i18n catalog files at build time
    (extending the S16 awk-script pattern). Default to whatever
    locale F13 ships; offer multi-locale overrides if the
    frontend catalogs are split.
  - Wizard step / Settings panel: structured editor (one row
    per key with default value + override field), not a raw
    JSON blob.

  Tightest coupling to upstream of any story in this phase. If
  F13's frontend i18n structure changes, this breaks.

  **Loop-runnable** for the wiring; maintainer validates each
  upstream frontend bump.

- [ ] **S115: Branding panel (GUI)**

  A dedicated `/settings/branding` route in the GUI that bundles
  S112 + S113 + S114 into one workflow:
  - Upload logo + favicon
  - Pick color palette
  - Edit text strings
  - "Apply branding" button → triggers full frontend rebuild
    (re-uses the existing `secrets → render → build → pull →
    start` pipeline from the wizard run page, but only the
    `build → pull → start` half).

  Live preview if S113 makes it cheap; otherwise a "this will
  take 1–3 minutes" confirmation modal.

  **Loop-runnable.**

> **Risk note for Phase 16:** every upstream F13 frontend release
> needs a patch-compatibility check. Recommend documenting a
> dedicated "branding regression test" the maintainer runs whenever
> `_FRONTEND_GIT_REF` is bumped: build with a known reference
> branding override, smoke-test that the patches still apply
> cleanly, that the rebuilt image shows the expected branding.
> Without that gate, a v0.4.0 frontend bump could silently break
> v0.11.0 branding for all users.

---

## Release roadmap

The PRD's story sequence maps onto the GitHub release line as follows:

| Release | Phase(s) | Status | Highlight |
|---|---|---|---|
| v0.1.0 | Phase 0–6 (S00–S16) | shipped | Shell wizard + patched-frontend image gating |
| v0.2.0 | Phase 7 (S17–S31) + wiring fixes | shipped | Tauri 2 + Svelte 5 desktop GUI, click-through works |
| v0.2.1 | Design polish (no new phase) | shipped | Zinc visual direction across all seven screens |
| v0.2.2 | Phase 7.5 (S32 + S34) + HF1 + UX polish + dependabot | shipped | macOS GUI mostly stable for daily local use. Loop landed S32 + S34; HF1 done across four iterations; Stop/Start cycle, Stopped badge, Reset Enter-key, Ollama free-text/cloud links; cookie 0.7 override + 2 Rust alerts dismissed; 288/288 vitest. HF2 + HF3 deferred (don't block normal use). |
| v0.3.0 | **Phase 8 (S37–S40)** Linux runtime parity + image pinning + UX polish | shipped | GUI mostly stable on macOS + Linux (WSL2 Ubuntu 22.04 validated). Maintainer hand-fixes: secret-file mode 0644 for Linux bind-mounts (S39), `apply_linux_runtime_defaults()` silences libEGL/DMA-BUF warnings (S37), `host.docker.internal:host-gateway` confirmed under WSL2 + Docker Desktop (S38), `feedback_db.secret` round-trips through `edit` so postgres volume stays aligned, Tailwind v4 ProgressBar keyframe hoist, embedding-model alert in Ollama picker, soft warnings against embedding selections, image pins (core v2.0.0, chat v1.2.0, postgres 17, frontend git ref v2.0.0 → `f13-frontend:v2.0.0_based`), `frontend::get_source` always clones the pinned tag. HF4 (reconfigure no-op on backend swap) found and documented; doesn't block normal use. Ralph loop NOT used for any of this — interactive maintainer + Claude Code sessions on the actual Linux box. |
| v0.3.1 | **HF4** — reconfigure flow re-renders on backend swap | shipped | Single ship covering three compounding bugs (env clobber in `state::read`, `F13_STATE_ACTION` shadowed before `state::check`, running stack not stopped before re-render) plus a GUI early-stop on the Reconfigure button so the wizard's port-check screen sees free ports. Validated on macOS via manual smoke (mock → Ollama → mock → fresh init); Linux validation deferred to next WSL2 session — pure logic/state-machine fix, no Linux-specific surface. PR #1 squashed as `f342a1f`. Ralph loop NOT used. |
| v0.3.2 | **HF2 + HF3 + tauri 2.11.1** — Cancel kills wizard subprocess; missing-image precondition; Dependabot bump | shipped | HF2 plumbed `AbortSignal` end-to-end with a double-down mitigation for the orphaned `docker compose up` grandchild (proper kill-process-group fix deferred). HF3 pinned `pull_policy: never` on the frontend service and added a `docker image inspect` precondition in `compose::up` with the failure reason propagated through `COMPOSE_ERROR_MESSAGE` into the `done` event so the GUI's toast surfaces the friendly text. Tauri 2.10.3 → 2.11.1 via Dependabot #2 (Cargo.lock only). PR #3 squashed as `69f9bff`. Ralph loop NOT used. |
| v0.4.0 | **Phase 9 (S41–S44)** GUI localization + zoom | shipped | English / German / French / Spanish translations of every GUI string (176 keys × 4 locales, key parity enforced in CI); locale picker on the welcome screen only, persisted to `f13.configurator.locale`; zoom via `Ctrl/Cmd + +/−/0` shortcuts and a `−` / `100%` / `+` stepper in Settings → Appearance, factor persisted to `f13.configurator.zoom`. Shell wizard terminal output stays English. Ralph loop drove S41–S44; maintainer review added the LS key rename + Settings absence test + localization gaps in the Ollama prose / ports note / reset modal as follow-ups. PR #4 squashed as `dc3d10f`. |
| v0.5.0 | **Phase 10 (S51–S56)** Signed distributables + bundled-mode data paths | planned | `appLocalDataDir` for bundled installs (replaces dev-only path), `f13-stop`/`f13-reset` discovery, signed `.dmg` (macOS arm64 only), `.AppImage` + `.deb` (Linux x86_64 only), GitHub Releases automation with draft + manual publish. Feature branch `feat/phase10-distributables`, single PR. S51 + S52 loop-runnable; S53–S56 maintainer-driven (Apple cert, GitHub release secrets). |
| v0.6.0 | **Phase 11 (S61 + S62)** UX polish + auto-update | planned | S61: auto-regenerate broken stack on Start instead of forcing user through Reconfigure wizard (former HF5, promoted to a real story since it's pure GUI plumbing). S62: optional Tauri auto-update with separate updater keypair and signed manifest in the GitHub Release (former S57). Feature branch `feat/phase11-polish-autoupdate`, single PR. |
| v0.7.0 | **Phase 12 (S71–S73)** Homebrew distribution | planned | macOS users can `brew install --cask f13-configurator` from a maintainer-owned tap (`revolutionaryPhoton/homebrew-f13`). GitHub Releases remain the canonical artifact source. S73 (release-workflow integration to auto-bump the cask formula) is optional. Feature branch `feat/phase12-homebrew`, single PR. |
| v0.8.0 | **Phase 13 (S81–S86)** Full preset — RAG + summary + parser | planned | New `full` preset alongside today's `basic`. RAG, summary, parser services templated and gated by Compose profiles + `ENABLED_FEATURES`. Ollama picker grows an embedding-model selection when RAG is in the preset. Preflight learns to estimate per-service RAM/disk against host resources. Single preset radio (basic / full), no per-service toggles yet. Transcription explicitly deferred. Feature branch `feat/phase13-full-preset`, single PR. Mostly loop-runnable; S81 (upstream catalog research) is maintainer-driven. |
| v0.9.0 | **Phase 14 (S91–S94)** User-adjustable microservice set | planned | Replace the basic/full radio with a checkbox grid — users mix and match services. Live resource estimation as toggles flip. Dependency enforcement (RAG → embedding model on Ollama path, summary → parser as a hard dependency auto-ticked, parser standalone is fine, chat always required). `COMPOSE_PROFILES` + `ENABLED_FEATURES` derived from the selection. Pure UX layer on Phase 13's templates. Feature branch `feat/phase14-adjustable-services`, single PR. Fully loop-runnable. |
| v0.10.0 | **Phase 15 (S101–S103)** Chat parameter tuning | planned | System prompt, temperature, max input/output tokens exposed in Settings → Chat (GUI) and an optional `--edit-chat-params` flow (shell). Persists to `.state`; chat service restarts on save. No new services, no upstream coordination. Smallest post-distribution phase. Feature branch `feat/phase15-chat-params`, single PR. Fully loop-runnable. |
| v0.11.0 | **Phase 16 (S111–S115)** Branding / text customization | planned | Logo + favicon upload, color palette picker, text-string overrides — all wired through the existing S16 patched-frontend-build mechanism (no upstream F13 cooperation available, per 2026-05 maintainer decision). Every branding change triggers a ~1–3 min frontend rebuild. Tightly coupled to the pinned `_FRONTEND_GIT_REF`; each upstream frontend bump needs a branding-regression smoke-test. Feature branch `feat/phase16-branding`, single PR. Loop-runnable for wiring; S111 (surface inventory) maintainer-driven. |

Linux runtime parity (Phase 8) shipped in v0.3.0 via
maintainer-side WSL2 testing. HF4 landed as v0.3.1; HF2 + HF3
landed as v0.3.2 alongside the tauri 2.11.1 Dependabot bump;
Phase 9 (i18n + zoom) shipped as v0.4.0 — the first phase the
ralph loop drove end-to-end since Phase 7.5. HF5 (auto-regenerate
broken stack on Start) was promoted from a maintainer hand-fix
to a planned story — it's tracked as **S61** in Phase 11. Phase
10 (signed distributables, was originally Phase 9, retargeted to
v0.5.0) is gated on the maintainer's Apple Developer enrollment
and GitHub repo secrets being in place. Phase 11 (v0.6.0) bundles
the auto-update story (former S57) with HF5/S61 once Phase 10 has
shipped. Phase 12 (v0.7.0) adds Homebrew cask distribution as a
convenience layer on top of the canonical GitHub Releases.

Phases 13–16 are the **feature-completeness arc** — taking the
configurator from "the simplest possible F13" to "every F13
microservice, mixed and matched, with chat tuning and full
branding overrides." Phase 13 ships the `full` preset (RAG +
summary + parser) as an opinionated bundle (v0.8.0). Phase 14
replaces the basic/full radio with a per-service checkbox grid
(v0.9.0). Phase 15 adds chat parameter tuning — system prompt,
temperature, token limits (v0.10.0). Phase 16 lets organizations
rebrand F13 by patching the upstream frontend image with custom
logo, colors, and text strings at build time — the only viable
path since F13's frontend doesn't support runtime overrides
(v0.11.0). Transcription is explicitly out of scope across all
these phases; if there's demand, a future Phase 17 "specialty
services" bucket would pick it up.

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
