#!/bin/bash
set -e

# agtx sandbox launcher — runs the compose definition (sandbox by default, or
# runtime with AGTX_RUNTIME=1). Picks docker/podman, pre-creates host paths,
# plants the macOS Keychain credential, attaches the terminal, captures exit.
# Customize: copy compose.yaml (or compose.runtime.yaml) to compose.custom.yaml
# (gitignored) and edit it; sandbox.sh uses it when present.

# Resolve the caller's dir: the project arg (and default) is relative to it.
CALLER_PWD="$(pwd)"
DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DOCKER_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}==>${NC} $1"; }
warn()    { echo -e "${YELLOW}==>${NC} $1"; }
error()   { echo -e "${RED}==>${NC} $1"; exit 1; }

# realpath is missing on some macOS versions
resolve_path() {
    cd "$1" && pwd -P
}

# docker when installed, else podman (override: AGTX_CONTAINER_RUNTIME)
CR="${AGTX_CONTAINER_RUNTIME:-docker}"
command -v "$CR" &>/dev/null || CR=podman
command -v "$CR" &>/dev/null || error "no container runtime found — install docker or podman"

# Mode + base compose file. A gitignored compose.custom.yaml wins and is
# self-describing (its AGTX_MODE drives the mode); else AGTX_RUNTIME=1 picks
# runtime, anything else is sandbox.
if [ -f "compose.custom.yaml" ]; then
    BASE=compose.custom.yaml
    # Match the real env-list item, not a comment mentioning AGTX_MODE=runtime.
    if grep -Eq '^[[:space:]]*-[[:space:]]*AGTX_MODE=runtime' "compose.custom.yaml"; then
        MODE=runtime
    else
        MODE=sandbox
    fi
elif [ "${AGTX_RUNTIME:-0}" = "1" ]; then
    MODE=runtime; BASE=compose.runtime.yaml
else
    MODE=sandbox; BASE=compose.yaml
fi
# Read container_name from the base file; fall back to the mode convention.
CN="$(grep -Eo '^[[:space:]]*container_name:[[:space:]]*[^[:space:]]+' "$BASE" | head -n1 | awk '{print $2}')"
CONTAINER="${CN:-$([ "$MODE" = runtime ] && echo agtx-runtime || echo agtx-sandbox)}"

# Sandbox networking: host by default on Linux (so the sandbox reaches the
# host's own services, e.g. Ollama on localhost). Podman on macOS can't do
# host networking, so it stays bridge there. AGTX_HOST_NETWORK=1/0 forces it.
NET=""
if [ "$MODE" = sandbox ]; then
    case "${AGTX_HOST_NETWORK:-}" in
        1) NET=host ;;
        0) NET= ;;
        *) [ "$(uname -s)" != "Darwin" ] && NET=host ;;
    esac
fi
export SANDBOX_NET_MODE="${NET:-bridge}"

RAW_PROJECT="${1:-$CALLER_PWD}"

# We're in docker/ for compose, so resolve a relative project path against the
# caller's directory.
case "$RAW_PROJECT" in
    /*) ;;
    *)  RAW_PROJECT="$CALLER_PWD/$RAW_PROJECT" ;;
esac

if [ ! -d "$RAW_PROJECT" ]; then
    error "Directory not found: $RAW_PROJECT"
fi

PROJECT="$(resolve_path "$RAW_PROJECT")"
# Runtime mode mounts the project under its own name so agtx derives the real
# project name (and path-keyed DB) instead of the generic "workspace".
PROJECT_NAME="$(basename "$PROJECT")"

# Pre-create the host config paths we mount, as the host user, so a bind mount
# never auto-creates them root-owned. Empty ones no-op in the entrypoint; the
# JSON file gets a valid empty object (not zero bytes).
mkdir -p "${HOME}/.config/agtx/plugins" "${HOME}/.config/opencode" "${HOME}/.claude"
[ -f "${HOME}/.claude.json" ]             || printf '{}\n' > "${HOME}/.claude.json"
[ -f "${HOME}/.config/agtx/config.toml" ] || touch "${HOME}/.config/agtx/config.toml"

echo ""
echo "  ╭──────────────────────────────────────────╮"
echo "  │               agtx sandbox               │"
echo "  ╰──────────────────────────────────────────╯"
echo ""

info "Project : $PROJECT"
info "Mode    : $MODE"
info "User    : sandbox (non-root, uid=$(id -u))"
info "Runtime : $CR (compose)"
[ "$MODE" = sandbox ] && info "Network : $SANDBOX_NET_MODE"
[ "$MODE" = runtime ] && info "Workspace : $PROJECT_NAME"

if [ ! -d "$PROJECT/.git" ]; then
    warn "$PROJECT is not a git repository"
    read -rp "  Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    echo ""
fi

# Expose identity to compose: build uses UID/GID; mounts reference resolved paths.
export PROJECT
export PROJECT_NAME
export AGTX_BUILD_UID="$(id -u)"
export AGTX_BUILD_GID="$(id -g)"

# Build the image with the host UID/GID so container-created files are owned correctly
info "Building image..."
"$CR" compose -f "$BASE" build
success "Image ready"
echo ""

# keep-id only applies to rootless Podman (Docker doesn't use userns_mode)
F="-f $BASE"
[ "$CR" = "podman" ] && [ "$(id -u)" -ne 0 ] && F="$F -f compose.keepid.yaml"

# macOS: the Claude OAuth token lives in the Keychain, not ~/.claude, so
# materialise the .credentials.json Claude Code writes on Linux. Piped via stdin
# (never to a host temp file or argv); planted after up, before attach. Needs
# `compose attach` (Docker only); the Keychain case is Darwin-only, so Podman
# never reaches this.
CLAUDE_CREDS=""
if [ "$(uname -s)" = "Darwin" ] && [ ! -f "${HOME}/.claude/.credentials.json" ]; then
    CLAUDE_CREDS="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
    if [ -z "$CLAUDE_CREDS" ]; then
        info "No Claude credentials found — the Keychain lookup failed (you may need"
        info "to allow access when prompted). Set ANTHROPIC_API_KEY, or the agent"
        info "inside the sandbox will report 'Not logged in'."
    fi
fi

# Drop any stale container from a previous run so the fixed container_name
# never conflicts.
"$CR" compose $F down >/dev/null 2>&1 || true

# Start detached, then attach: `compose up` attaches logs, not stdin, and the
# agtx TUI needs both. A non-zero code means agtx crashed, so don't let it trip
# `set -e` — capture explicitly.
EXIT=0
"$CR" compose $F up -d || EXIT=$?

if [ "$EXIT" -eq 0 ] && [ -n "$CLAUDE_CREDS" ] && [ "$CR" = "docker" ]; then
    printf '%s' "$CLAUDE_CREDS" | "$CR" compose $F exec -T sandbox \
        /bin/bash -c 'umask 077 && cat > /home/sandbox/.claude/.credentials.json'
    unset CLAUDE_CREDS
fi

ATTACHED=0
if [ "$EXIT" -eq 0 ]; then
    if [ ! -t 0 ]; then
        warn "stdin is not a TTY — the agtx TUI needs an interactive terminal"
    fi
    if [ "$CR" = "docker" ]; then
        "$CR" compose $F attach sandbox || ATTACHED=$?
    else
        # podman-compose has no `attach`; the fixed container_name lets the
        # native command do it.
        "$CR" attach "$CONTAINER" || ATTACHED=$?
    fi

    # Prefer the container's own exit status: attach can fail because the
    # container already stopped (which says nothing about why agtx exited). If
    # the container is still running (user detached), keep attach's status.
    container_code=$("$CR" inspect --format '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || true)
    if [ -n "$container_code" ]; then
        container_running=$("$CR" inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
        if [ "$container_running" = "true" ]; then
            EXIT=$ATTACHED
        else
            EXIT=$container_code
        fi
    else
        EXIT=$ATTACHED
    fi
fi

"$CR" compose $F down >/dev/null 2>&1 || true
exit "$EXIT"
