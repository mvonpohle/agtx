#!/bin/bash
set -e

# agtx sandbox — the isolated mode.
#
# The container is a JAIL: agtx's state lives in a named volume, and your host
# settings are staged read-only then copied into a disposable home, so nothing the
# agent does can reach the host. Only the one project you launch is mounted.
# (The opposite mode — runtime, where the container is agtx's host — is
# docker/runtime.sh.)
#
# This launcher only does what cannot be a compose value; the container definition
# is docker/compose.yaml, and the shared plumbing (runtime detection, image build,
# rootless-podman keep-id, the TUI attach/exit runner) is docker/common.sh, which
# is sourced below.
#
# Usage:
#   ./docker/sandbox.sh [path/to/project]     # (defaults to current directory)
#
# Customize:
#   * docker/.env            — host-specific values (gitignored; see .env.example)
#   * COMPOSE_OVERRIDE=<file> — an extra compose file (mounts/env/caps) merged in
#   * compose.yaml itself    — the base definition, edited directly
#
# Or drive Compose directly (skip this launcher):
#   PROJECT=/path/to/project docker compose -f docker/compose.yaml up -d
#   PROJECT=/path/to/project docker compose -f docker/compose.yaml attach sandbox

# Remember where the script was invoked: the project argument (and the default when
# none is given) is relative to the caller, not to this script's directory.
CALLER_PWD="$(pwd)"
DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DOCKER_DIR"

# Shared plumbing: logging, runtime detection, .env, networking, image build, keep-id,
# and the run_compose TUI runner. (Must be sourced from the docker/ directory, which
# we just cd'd into.)
# shellcheck source=common.sh
. ./common.sh

# --- resolve the project ---
RAW_PROJECT="${1:-$CALLER_PWD}"
case "$RAW_PROJECT" in
    /*) ;;
    *)  RAW_PROJECT="$CALLER_PWD/$RAW_PROJECT" ;;
esac
[ -d "$RAW_PROJECT" ] || error "Directory not found: $RAW_PROJECT"
PROJECT="$(resolve_path "$RAW_PROJECT")"
# compose.yaml mounts it at /home/sandbox/workspace (the generic sandbox name); the
# image build needs the host UID/GID (common.sh already exported them).
export PROJECT

echo ""
echo "  ╭──────────────────────────────────────────╮"
echo "  │         agtx sandbox (isolated)          │"
echo "  ╰──────────────────────────────────────────╯"
echo ""

info "Project : $PROJECT"
info "Mode    : sandbox (state isolated, host config staged read-only)"
info "User    : sandbox (non-root, uid=$(id -u))"
info "Runtime : $CR (compose)"
info "Network : $SANDBOX_NET_MODE"
[ -n "${COMPOSE_OVERRIDE:-}" ] && info "Override: $COMPOSE_OVERRIDE"

if [ ! -d "$PROJECT/.git" ]; then
    warn "$PROJECT is not a git repository"
    read -rp "  Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    echo ""
fi

# --- macOS Keychain credential planting (sandbox-specific) ---
# On macOS the Claude OAuth token lives in the Keychain, not ~/.claude, so copying
# that directory leaves the container on "Not logged in". Materialise the same
# .credentials.json Claude Code writes on Linux, into the disposable sandbox home.
#
# The secret is piped through stdin: never written to a host temp file, and never
# placed in argv where `ps` would expose it. It is captured here (before up) and
# planted by agtx_after_up (after up, before attach), so no agent starts first.
#
# This needs `compose exec`/`attach`, which Docker Compose has but podman-compose
# does not — and the Keychain case is Darwin-only, where the runtime is Docker. On
# Podman (Linux) there is no Keychain credential to plant, so it never fires.
CLAUDE_CREDS=""
if [ "$(uname -s)" = "Darwin" ] && [ ! -f "${HOME}/.claude/.credentials.json" ]; then
    CLAUDE_CREDS="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
    if [ -z "$CLAUDE_CREDS" ]; then
        info "No Claude credentials found — the Keychain lookup failed (you may need"
        info "to allow access when prompted). Set ANTHROPIC_API_KEY, or the agent"
        info "inside the sandbox will report 'Not logged in'."
    fi
fi

agtx_after_up() {
    local F="$1"
    if [ -n "${CLAUDE_CREDS:-}" ] && [ "$CR" = "docker" ]; then
        printf '%s' "$CLAUDE_CREDS" | "$CR" compose $F exec -T sandbox \
            /bin/bash -c 'umask 077 && cat > /home/sandbox/.claude/.credentials.json'
        unset CLAUDE_CREDS
    fi
}

run_compose compose.yaml agtx-sandbox
