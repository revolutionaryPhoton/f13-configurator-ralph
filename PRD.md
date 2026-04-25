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
- A GUI.
