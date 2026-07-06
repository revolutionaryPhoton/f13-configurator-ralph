# syntax=docker/dockerfile:1
# Custom Docker Sandboxes template for the Ralph loop (MODE=sbx).
# Extends Docker's official claude-code sandbox template with the F13
# configurator toolchain (shellcheck/bats/webkit/rust) so backpressure
# checks run inside the microVM.
# Built automatically by ./ralph.sh --sbx-check / MODE=sbx when missing.
FROM docker/sandbox-templates:claude-code

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root
# Debian toolchain set; per-package pins are impractical — template
# refreshes are explicit (docker build) rather than per-iteration.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
      shellcheck bats gettext-base curl ca-certificates \
      libwebkit2gtk-4.1-dev libglib2.0-dev libgtk-3-dev libssl-dev \
      build-essential librsvg2-dev patchelf libsoup-3.0-dev \
      libjavascriptcoregtk-4.1-dev \
    && rm -rf /var/lib/apt/lists/*

# Rust system-wide (world-writable caches for the sandbox user).
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- --default-toolchain stable -y --no-modify-path \
    && chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME"

# Git identity for loop commits — without it, git commit fails with
# "Author identity unknown" and the model invents its own identity.
# Same identity as docker mode (ARG-overridable for forks).
ARG GIT_USER_NAME="David Moch"
ARG GIT_USER_EMAIL="david.moch@gmail.com"
RUN git config --system init.defaultBranch main \
    && git config --system user.name "$GIT_USER_NAME" \
    && git config --system user.email "$GIT_USER_EMAIL"

# Restore the base template's unprivileged user.
USER agent
