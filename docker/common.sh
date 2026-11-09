#!/bin/bash
# agtx docker shared plumbing.
#
# Sourced (not executed) by docker/sandbox.sh and docker/runtime.sh. Both launchers
# cd into the docker/ directory first, so the relative .env / compose paths here are
# relative to docker/.
#
# This holds only what is truly identical across the two modes:
#   * logging, container-runtime detection, the user-local .env,
#   * networking (host vs bridge, for reaching a locally-hosted model),
#   * the image build and the rootless-podman keep-id override,
#   * pre-creating the host config paths both modes mount,
#   * the TUI runner: down-stale -> up -d -> (hook) -> attach -> capture exit -> down.
#
# The modes' *meaning* is different (sandbox = jail, runtime = portable install) and
# lives in the launchers and their compose files, not here.

# --- logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}==>${NC} $1"; }
warn()    { echo -e "${YELLOW}==>${NC} $1"; }
error()   { echo -e "${RED}==>${NC} $1"; exit 1; }

# --- helpers ---
# Resolve a path to its canonical form (realpath is not on all macOS versions).
resolve_path() { (cd "$1" && pwd -P); }

# --- container runtime: docker when installed, else podman (AGTX_CONTAINER_RUNTIME) ---
CR="${AGTX_CONTAINER_RUNTIME:-docker}"
command -v "$CR" &>/dev/null || CR=podman
command -v "$CR" &>/dev/null || error "no container runtime found — install docker or podman"

# --- user-local overrides (docker/.env, gitignored; holds host-specific values) ---
# The launcher exports what it reads, so the compose process sees the same values
# whether it is docker-compose or podman-compose (which may not parse .env itself).
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

# --- networking ---
# host by default (Linux) so the container reaches the host's loopback services
# (a locally-hosted model, e.g. Ollama on localhost). Off by default on macOS
# (podman can't host-network there). AGTX_HOST_NETWORK=1 forces on, =0 forces off.
# Applies to both modes: the model endpoint is a host network service.
NET=""
case "${AGTX_HOST_NETWORK:-}" in
    1) NET=host ;;
    0) NET= ;;
    *) [ "$(uname -s)" != "Darwin" ] && NET=host ;;
esac
export SANDBOX_NET_MODE="${NET:-bridge}"

# --- host identity (so bind-mounted files stay owned by the host user) ---
export AGTX_BUILD_UID="${AGTX_BUILD_UID:-$(id -u)}"
export AGTX_BUILD_GID="${AGTX_BUILD_GID:-$(id -g)}"

# --- pre-create the host config paths both modes mount (as the host user) ---
# Idempotent; stops the container runtime from auto-creating them root-owned. An
# empty one is a no-op at startup (see entrypoint.sh). The JSON file is seeded with
# valid empty JSON so a host-side reader never sees invalid JSON.
precreate_host_paths() {
    mkdir -p "${HOME}/.config/agtx/plugins" "${HOME}/.config/opencode" "${HOME}/.claude"
    [ -f "${HOME}/.claude.json" ]             || printf '{}\n' > "${HOME}/.claude.json"
    [ -f "${HOME}/.config/agtx/config.toml" ] || touch "${HOME}/.config/agtx/config.toml"
}

# --- image build ---
build_image() {  # $1 = base compose file
    info "Building image..."
    "$CR" compose -f "$1" build
    success "Image ready"
}

# --- compose flags: base file + optional user override + rootless-podman keep-id ---
compose_flags() {  # $1 = base compose file
    local F="-f $1"
    [ -n "${COMPOSE_OVERRIDE:-}" ] && F="$F -f ${COMPOSE_OVERRIDE}"
    # keep-id: rootless Podman maps container uid 0 to the invoking host user, so
    # running as 0 gives correct ownership AND access to 700/NFS host dirs. Docker
    # keeps the base files' user: sandbox. (See compose.keepid.yaml.)
    [ "$CR" = "podman" ] && [ "$(id -u)" -ne 0 ] && F="$F -f compose.keepid.yaml"
    printf '%s' "$F"
}

# --- the TUI runner (shared by both launchers) ---
# $1 = base compose file, $2 = container name (agtx-sandbox / agtx-runtime).
# Calls agtx_after_up (if the launcher defined it) after `up -d`, before attach —
# the sandbox uses this for the macOS Keychain planting; the runtime leaves it unset.
# Ends with `exit`, since it is the launcher's final action.
run_compose() {
    local BASE="$1" CONTAINER="$2"
    local F EXIT=0 ATTACHED=0 code running

    precreate_host_paths
    build_image "$BASE"
    F="$(compose_flags "$BASE")"

    # Best-effort: drop a stale container from a previous run (fixed name).
    "$CR" compose $F down >/dev/null 2>&1 || true

    # up detached, then attach — foreground `up` attaches logs, not stdin, and the
    # agtx TUI needs both. A non-zero code means agtx crashed, so failures must not
    # trip `set -e`; capture them explicitly.
    "$CR" compose $F up -d || EXIT=$?

    # mode-specific hook (e.g. sandbox's macOS Keychain planting); no-op if unset.
    if [ "$EXIT" -eq 0 ] && [ "$(type -t agtx_after_up 2>/dev/null)" = "function" ]; then
        agtx_after_up "$F" || true
    fi

    if [ "$EXIT" -eq 0 ]; then
        [ -t 0 ] || warn "stdin is not a TTY — the agtx TUI needs an interactive terminal"
        if [ "$CR" = "docker" ]; then
            "$CR" compose $F attach sandbox || ATTACHED=$?
        else
            # podman-compose has no `attach`; the fixed container name lets the
            # runtime-native command do it.
            "$CR" attach "$CONTAINER" || ATTACHED=$?
        fi
        # Prefer the container's own exit status over attach's (attach can fail
        # merely because the container already stopped, which says nothing about why
        # agtx exited). If the container is still running (e.g. the user detached),
        # keep attach's status instead of the running container's placeholder 0.
        code=$("$CR" inspect --format '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || true)
        if [ -n "$code" ]; then
            running=$("$CR" inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
            if [ "$running" = "true" ]; then
                EXIT=$ATTACHED
            else
                EXIT=$code
            fi
        else
            EXIT=$ATTACHED
        fi
    fi

    "$CR" compose $F down >/dev/null 2>&1 || true
    exit "$EXIT"
}
