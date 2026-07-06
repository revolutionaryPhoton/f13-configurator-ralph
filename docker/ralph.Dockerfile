# syntax=docker/dockerfile:1
# Prebuilt Ralph loop sandbox image. Build via ./ralph.sh --build
# All toolchain deps are baked here so iterations start in seconds and the
# supply chain is pinned instead of re-fetched every iteration.
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:b31e7a42fdf8b8aa5f5ed477c72d694301273f1069c5a2f71d53c6482e99a2fc
FROM ${NODE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CLAUDE_CODE_VERSION=2.1.201
ARG UID=501
ARG GID=20
ARG GIT_USER_NAME="David Moch"
ARG GIT_USER_EMAIL="david.moch@gmail.com"

# Baked host identity — ensure_docker_image compares these labels against
# the current host uid/gid and auto-rebuilds on mismatch (e.g. after
# moving the repo between macOS uid 501 and Linux uid 1000).
LABEL f13.ralph.uid="${UID}" f13.ralph.gid="${GID}"

# Debian toolchain set; per-package pins are impractical — the base image
# digest pin fixes the apt snapshot instead.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
      git shellcheck bats gettext-base curl wget ca-certificates \
      iptables ipset dnsutils procps \
      libwebkit2gtk-4.1-dev libglib2.0-dev libgtk-3-dev libssl-dev \
      build-essential librsvg2-dev patchelf libsoup-3.0-dev \
      libjavascriptcoregtk-4.1-dev \
    && rm -rf /var/lib/apt/lists/*

# Rust system-wide (official rust-image pattern; world-writable so the
# non-root user can use the shared cargo registry cache).
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- --default-toolchain stable -y --no-modify-path \
    && chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME"

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# Non-root 'ralph' user matching the host uid/gid (replaces the old runtime
# remap). The base image ships 'node' at uid 1000 — rename on collision.
RUN set -eux; \
    if getent passwd "$UID" >/dev/null; then \
      usermod -l ralph -d /home/ralph -m "$(getent passwd "$UID" | cut -d: -f1)"; \
    else \
      getent group "$GID" >/dev/null || groupadd -g "$GID" ralph; \
      useradd -l -m -u "$UID" -g "$GID" -s /bin/bash ralph; \
    fi

# Git posture baked at system level; GIT_AUTHOR_*/GIT_COMMITTER_* env can
# still override at run time.
RUN git config --system init.defaultBranch main \
    && git config --system user.name "$GIT_USER_NAME" \
    && git config --system user.email "$GIT_USER_EMAIL" \
    && git config --system --add safe.directory /workspace

COPY init-firewall.sh ralph-entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/ralph-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ralph-entrypoint.sh"]
