#!/bin/bash
set -e

# agtx runtime — the portable-install mode.
#
# The container is agtx's HOST: your real config and state (agtx, OpenCode, Claude)
# are mounted writable, so agtx behaves like a local install — for machines that
# lack the dependencies to run agtx natively. This is the opposite of the sandbox
# (docker/sandbox.sh), where the container is a jail and only one project is
# reachable.
#
# Because your real projects are what you're switching between, runtime mounts the
# shared projects ROOT (PROJECTS_DIR) by default, so every project in it is reachable
# in the agtx sidebar (agtx skips a project whose path is absent, so an unmounted
# project is unreachable). Set PROJECTS_DIR in docker/.env; leave it unset to mount
# only the single launched project.
#
# This launcher is intentionally thin: the container definition is
# docker/compose.runtime.yaml, the shared plumbing is docker/common.sh (sourced
# below), and the flexibility lives in docker/.env and (for structure) a compose
# override.
#
# Usage:
#   ./docker/runtime.sh [path/to/project]    # (defaults to current directory)
#
# Customize:
#   * docker/.env              — PROJECTS_DIR, AGTX_HOST_NETWORK, AGTX_CONTAINER_RUNTIME, ...
#   * COMPOSE_OVERRIDE=<file>  — an extra compose file (mounts/env/caps) merged in
#   * compose.runtime.yaml     — the base definition, edited directly
#
# Or drive Compose directly (skip this launcher) — you must set WORKSPACE_MOUNT:
#   WORKSPACE_MOUNT=/path/to/project:/home/sandbox/workspaces/project \
#       docker compose -f docker/compose.runtime.yaml up -d

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
# The launched project's name (basename) is where it lives under the workspaces root,
# and what agtx registers it as.
PROJECT_NAME="$(basename "$PROJECT")"

# --- the workspace mount (the thing that makes projects reachable) ---
# PROJECTS_DIR set -> mount the whole root at /home/sandbox/workspaces, so every
# project in it is at /home/sandbox/workspaces/<name> and switchable in the sidebar.
# Unset        -> mount only the launched project under its own name.
# It is one flat "source:target" value: podman-compose's substitution breaks on
# nested ${VAR:-default}, so the launcher resolves it to a single flat string.
if [ -n "${PROJECTS_DIR:-}" ]; then
    PROJECTS_DIR="$(resolve_path "$PROJECTS_DIR")"
    [ "$(dirname "$PROJECT")" = "$PROJECTS_DIR" ] \
        || error "PROJECTS_DIR ($PROJECTS_DIR) must be the parent of PROJECT ($PROJECT)"
    WORKSPACE_MOUNT="$PROJECTS_DIR:/home/sandbox/workspaces"
else
    WORKSPACE_MOUNT="$PROJECT:/home/sandbox/workspaces/$PROJECT_NAME"
fi

export PROJECT PROJECT_NAME WORKSPACE_MOUNT

echo ""
echo "  ╭──────────────────────────────────────────╮"
echo "  │     agtx runtime (portable install)      │"
echo "  ╰──────────────────────────────────────────╯"
echo ""

info "Project : $PROJECT"
info "Mode    : runtime (real config/state, your real projects)"
if [ "$CR" = "podman" ] && [ "$(id -u)" -ne 0 ]; then
    info "User    : 0 (rootless-podman maps it to host uid $(id -u))"
else
    info "User    : sandbox (non-root, uid=$(id -u))"
fi
info "Runtime : $CR (compose)"
info "Network : $SANDBOX_NET_MODE"
info "Workspace : /home/sandbox/workspaces/${PROJECT_NAME}"
[ -n "${PROJECTS_DIR:-}" ] && info "Projects  : $PROJECTS_DIR (all sibling projects switchable in the sidebar)"
[ -n "${COMPOSE_OVERRIDE:-}" ] && info "Override: $COMPOSE_OVERRIDE"

if [ ! -d "$PROJECT/.git" ]; then
    warn "$PROJECT is not a git repository"
    read -rp "  Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    echo ""
fi

# The runtime mounts your real config/state and needs no Keychain planting or staging,
# so agtx_after_up is intentionally left undefined here (run_compose treats a missing
# hook as a no-op).

run_compose compose.runtime.yaml agtx-runtime
