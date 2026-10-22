#!/bin/bash
set -e

# agtx sandbox
# Usage: ./docker/sandbox.sh [options] [path/to/project]  (project defaults to current directory)

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Resolve project path portably (realpath not available on all macOS versions)
resolve_path() {
    cd "$1" && pwd -P
}

# Trim leading/trailing whitespace (no sed dependency)
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

usage() {
    cat <<'EOF'
agtx sandbox — run agtx in an isolated container (Docker or Podman).

Usage: sandbox.sh [options] [project-dir]

  project-dir defaults to the current directory.

Options:
  --mount SRC[:DST][:ro|rw]   Expose a host path inside the sandbox. Repeatable.
                              DST defaults to /sandbox/mounts/<basename>; mode
                              defaults to ro — read/write must be requested
                              explicitly.
  --mounts-file FILE          One --mount entry per line; full-line '#' comments.
  --compose                   Force Docker/Podman Compose mode.
  --no-compose                Force native run mode (the default). Ignores any
                              user compose override file.
  --print                     Print the exact commands that would be run, then
                              exit without building, starting, or prompting.
  -h, --help                  Show this help.

Environment:
  AGTX_CONTAINER_RUNTIME      docker | podman (default: docker, else podman)
  AGTX_SANDBOX_MOUNTS         Comma-separated --mount entries
  AGTX_SANDBOX_COMPOSE_FILE   Path to a user compose override file
  AGTX_HOST_NETWORK           1 = force host networking, 0 = force bridge

Compose mode is enabled automatically when <script dir>/sandbox.compose.yaml
exists, or when AGTX_SANDBOX_COMPOSE_FILE points at one. Your override file is
merged over the canonical base (docker/docker-compose.yaml); add entries under
services.agtx.volumes. See docker/sandbox.compose.example.yaml.

Default exposed paths (staged read-only and copied in at startup — the sandbox
never writes back to the host; agtx state lives in the 'agtx-data' volume):
  <project>                    -> /home/sandbox/workspace   (rw)
  ~/.claude                    -> staged ro, copied to ~/.claude
  ~/.claude.json               -> staged ro, copied to ~/.claude.json
  ~/.config/agtx/config.toml   -> staged ro, copied to ~/.config/agtx/
  ~/.config/agtx/plugins/      -> staged ro, copied to ~/.config/agtx/plugins/
  ~/.config/opencode           -> staged ro, copied to ~/.config/opencode/
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

RAW_PROJECT=""
EXTRA_SPECS=()
MOUNTS_FILE=""
COMPOSE_FORCE="auto"   # auto | on | off
PRINT_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --mount)
            [ $# -ge 2 ] || error "--mount needs a value (see --help)"
            EXTRA_SPECS+=("$2")
            shift 2
            ;;
        --mounts-file)
            [ $# -ge 2 ] || error "--mounts-file needs a value"
            MOUNTS_FILE="$2"
            shift 2
            ;;
        --compose)    COMPOSE_FORCE="on";  shift ;;
        --no-compose) COMPOSE_FORCE="off"; shift ;;
        --print)      PRINT_ONLY=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           error "unknown option: $1 (see --help)" ;;
        *)
            [ -z "$RAW_PROJECT" ] || error "multiple project paths given (see --help)"
            RAW_PROJECT="$1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Extra-path model — one shared list of user-chosen exposed paths
# ---------------------------------------------------------------------------
# Every source (--mount flags, AGTX_SANDBOX_MOUNTS, --mounts-file) feeds
# add_mount(); both runtime modes (native `run` and compose) render from this
# list. This is the single source of truth for user-exposed paths.

M_SRC=()
M_DST=()
M_MODE=()

# Container paths the sandbox itself uses. A user mount colliding with one of
# these would shadow the staged copies the entrypoint depends on.
RESERVED_DSTS="/ /home /home/sandbox /home/sandbox/workspace /claude-host /claude-host.json /agtx-host-config.toml /agtx-host-plugins /opencode-host"

expand_home() {
    local p="$1"
    # shellcheck disable=SC2088  # the tilde must stay literal (it is the match, not an expansion)
    case "$p" in
        "~")   printf '%s' "$HOME" ;;
        "~/"*) printf '%s/%s' "$HOME" "${p:2}" ;;
        *)     printf '%s' "$p" ;;
    esac
}

is_reserved_dst() {
    local d="$1" r
    # shellcheck disable=SC2086  # intentional word splitting of a fixed list
    for r in $RESERVED_DSTS; do
        if [ "$d" = "$r" ]; then return 0; fi
    done
    return 1
}

find_dst_index() {
    local d="$1" i
    for i in "${!M_DST[@]}"; do
        if [ "${M_DST[$i]}" = "$d" ]; then printf '%s' "$i"; return 0; fi
    done
    return 1
}

add_mount() {
    local src="$1" dst="$2" mode="$3" i secret

    src="$(expand_home "$src")"
    if [ -z "$src" ]; then error "empty host path in mount"; fi
    case "$src" in /*) ;; *) error "mount host path must be absolute (got: $1)"; esac
    if [ ! -e "$src" ]; then
        error "mount host path does not exist: $src (refusing — the runtime would create it)"
    fi
    case "$dst" in /*) ;; *) error "mount container path must be absolute (got: $2)"; esac
    case "$mode" in ro|rw) ;; *) error "mount mode must be 'ro' or 'rw' (got: $3)"; esac
    if is_reserved_dst "$dst"; then
        error "container path collides with a reserved sandbox path: $dst"
    fi

    i="$(find_dst_index "$dst" || true)"
    if [ -n "$i" ]; then
        warn "overriding earlier mount to $dst"
        M_SRC[i]="$src"
        M_MODE[i]="$mode"
    else
        M_SRC+=("$src")
        M_DST+=("$dst")
        M_MODE+=("$mode")
    fi

    if [ "$mode" = "rw" ]; then
        warn "mount $src -> $dst is read/write — the agent can modify it"
    fi
    if [ "$src" = "$HOME" ]; then warn "exposing your entire home directory ($src)"; fi
    if [ "$src" = "/" ]; then warn "exposing the filesystem root"; fi
    for secret in "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.config/gcloud" "$HOME/.docker"; do
        case "$src" in
            "$secret"|"$secret"/*) warn "mount looks like a secret store: $src" ;;
        esac
    done
    return 0
}

# Parse one "SRC[:DST][:ro|rw]" spec and add it.
parse_mount_spec() {
    local spec="$1" src dst="" mode="ro" n b
    local parts
    IFS=':' read -r -a parts <<< "$spec"
    n=${#parts[@]}
    if [ "$n" -lt 1 ] || [ -z "${parts[0]}" ]; then error "empty mount spec (in: $spec)"; fi
    src="${parts[0]}"
    if [ "$n" -ge 2 ]; then
        case "${parts[1]}" in
            ro|rw) mode="${parts[1]}" ;;
            *)
                dst="${parts[1]}"
                if [ "$n" -ge 3 ]; then mode="${parts[2]}"; fi
                ;;
        esac
    fi
    if [ -z "$dst" ]; then
        b="$(basename "$src")"
        if [ -z "$b" ] || [ "$b" = "/" ]; then b="root"; fi
        dst="/sandbox/mounts/$b"
    fi
    add_mount "$src" "$dst" "$mode"
}

# Sources are parsed in ascending precedence (file < env < CLI flags): for the
# same container target, a later source overrides an earlier one.
#
# --mounts-file — one entry per line, full-line '#' comments
if [ -n "$MOUNTS_FILE" ]; then
    if [ ! -f "$MOUNTS_FILE" ]; then error "mounts file not found: $MOUNTS_FILE"; fi
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="$(trim "$_line")"
        if [ -z "$_line" ] || [ "${_line:0:1}" = "#" ]; then continue; fi
        parse_mount_spec "$_line"
    done < "$MOUNTS_FILE"
fi

# AGTX_SANDBOX_MOUNTS env var — comma-separated, same entry syntax
if [ -n "${AGTX_SANDBOX_MOUNTS:-}" ]; then
    _env_specs=()
    IFS=',' read -r -a _env_specs <<< "$AGTX_SANDBOX_MOUNTS"
    for _spec in "${_env_specs[@]}"; do
        _spec="$(trim "$_spec")"
        if [ -n "$_spec" ]; then parse_mount_spec "$_spec"; fi
    done
fi

# --mount flags (highest precedence)
for _spec in "${EXTRA_SPECS[@]}"; do
    parse_mount_spec "$_spec"
done

# ---------------------------------------------------------------------------
# Runtime, networking, user namespace
# ---------------------------------------------------------------------------

# Container runtime: docker when installed, else podman (AGTX_CONTAINER_RUNTIME
# overrides). --print mode detects but does not require an installed runtime.
CR="${AGTX_CONTAINER_RUNTIME:-docker}"
command -v "$CR" &>/dev/null || CR=podman
if [ "$PRINT_ONLY" -eq 0 ]; then
    command -v "$CR" &>/dev/null || error "no container runtime found — install docker or podman"
fi

# Rootless podman remaps UIDs; keep-id preserves host ownership on bind mounts.
# 'host' is the only userns value Docker accepts, so compose interpolates
# userns_mode: keep-id only for rootless podman, host otherwise.
USERNS_MODE="host"
if [ "$CR" = "podman" ] && [ "$(id -u)" -ne 0 ]; then USERNS_MODE="keep-id"; fi

# `--network host` lets the sandbox reach the host's own services. That is what a
# locally-hosted model needs (e.g. Ollama on localhost, which a bridge network
# would hide behind the container's own loopback). Claude needs no such access —
# it talks to Anthropic's cloud — so this only matters for local-model setups.
# Podman on macOS cannot set up host networking (crun fails with an OCI
# permission error), so it is off by default there; AGTX_HOST_NETWORK=1 forces
# it on and =0 forces it off.
NET_MODE="bridge"
case "${AGTX_HOST_NETWORK:-}" in
    1) NET_MODE="host" ;;
    0) NET_MODE="bridge" ;;
    *) if [ "$(uname -s)" != "Darwin" ]; then NET_MODE="host"; fi ;;
esac

# The entrypoint needs to know whether the container's localhost reaches the
# host (host networking) or not (bridge); it uses this to adapt local-model
# provider configs. See entrypoint.sh.
export SANDBOX_NET_MODE="$NET_MODE"

# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------

RAW_PROJECT="${RAW_PROJECT:-$(pwd)}"

if [ ! -d "$RAW_PROJECT" ]; then
    error "Directory not found: $RAW_PROJECT"
fi

PROJECT="$(resolve_path "$RAW_PROJECT")"

# ---------------------------------------------------------------------------
# Compose mode selection
# ---------------------------------------------------------------------------
# Native `run` mode is the default. Compose mode is enabled by --compose, or
# automatically when a user override file is present — that file IS the
# compose-mode feature (user-added volumes merged over the canonical base).

BASE_COMPOSE="$DOCKER_DIR/docker-compose.yaml"
USER_OVERRIDE_FILE="${AGTX_SANDBOX_COMPOSE_FILE:-}"
if [ -z "$USER_OVERRIDE_FILE" ] && [ -f "$DOCKER_DIR/sandbox.compose.yaml" ]; then
    USER_OVERRIDE_FILE="$DOCKER_DIR/sandbox.compose.yaml"
fi

COMPOSE_MODE=0
case "$COMPOSE_FORCE" in
    on)  COMPOSE_MODE=1 ;;
    off) COMPOSE_MODE=0 ;;
    auto) if [ -n "$USER_OVERRIDE_FILE" ]; then COMPOSE_MODE=1; fi ;;
esac

if [ "$COMPOSE_MODE" -eq 1 ]; then
    if [ ! -f "$BASE_COMPOSE" ]; then
        error "compose base file missing: $BASE_COMPOSE"
    fi
    COMPOSE=("$CR" compose)
    if [ "$PRINT_ONLY" -eq 0 ]; then
        "${COMPOSE[@]}" version >/dev/null 2>&1 || \
            error "'$CR compose' is not usable — for docker install the compose plugin (check 'docker compose version'); for podman install podman-compose (e.g. 'brew install podman-compose')"
    fi
fi

# ---------------------------------------------------------------------------
# Native mode: assemble the full `run` argument list once, so --print and the
# real run can never drift apart, and paths with spaces stay single arguments.
# ---------------------------------------------------------------------------

RUN_ARGS=()
if [ "$COMPOSE_MODE" -eq 0 ]; then
    RUN_ARGS=(run -d -it --rm)
    if [ "$USERNS_MODE" = "keep-id" ]; then RUN_ARGS+=("--userns" "keep-id"); fi
    if [ "$NET_MODE" = "host" ]; then RUN_ARGS+=("--network" "host"); fi
    RUN_ARGS+=(
        "--security-opt" "no-new-privileges:true"
        "--cap-drop" "ALL"
        "--cap-add" "CHOWN"
        "--cap-add" "DAC_OVERRIDE"
        "--cap-add" "SETUID"
        "--cap-add" "SETGID"
        "-v" "${PROJECT}:/home/sandbox/workspace"
        "-v" "agtx-data:/home/sandbox/.config/agtx"
    )
    if [ -f "${HOME}/.claude.json" ]; then
        RUN_ARGS+=("-v" "${HOME}/.claude.json:/claude-host.json:ro")
    fi
    RUN_ARGS+=("-v" "${HOME}/.claude:/claude-host:ro")
    if [ -f "${HOME}/.config/agtx/config.toml" ]; then
        RUN_ARGS+=("-v" "${HOME}/.config/agtx/config.toml:/agtx-host-config.toml:ro")
    fi
    if [ -d "${HOME}/.config/agtx/plugins" ]; then
        RUN_ARGS+=("-v" "${HOME}/.config/agtx/plugins:/agtx-host-plugins:ro")
    fi
    if [ -d "${HOME}/.config/opencode" ]; then
        RUN_ARGS+=("-v" "${HOME}/.config/opencode:/opencode-host:ro")
    fi
    _i=0
    while [ "$_i" -lt "${#M_SRC[@]}" ]; do
        RUN_ARGS+=("-v" "${M_SRC[$_i]}:${M_DST[$_i]}:${M_MODE[$_i]}")
        _i=$((_i + 1))
    done
    RUN_ARGS+=("-w" "/home/sandbox/workspace" "agtx-sandbox" "agtx" "/home/sandbox/workspace")
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

echo ""
echo "  ╭──────────────────────────────────────────╮"
echo "  │               agtx sandbox               │"
echo "  ╰──────────────────────────────────────────╯"
echo ""

info "Project : $PROJECT"
info "User    : sandbox (non-root, uid=$(id -u))"
if [ "$COMPOSE_MODE" -eq 1 ]; then
    info "Mode    : compose ($CR compose)"
else
    info "Mode    : native ($CR run)"
fi
for i in "${!M_SRC[@]}"; do
    info "Mount   : ${M_SRC[$i]} -> ${M_DST[$i]} (${M_MODE[$i]})"
done

# rev-parse (not a .git directory test) so git *worktrees* — whose .git is a
# file pointing at the main repo — are recognised.
if ! git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    warn "$PROJECT is not a git repository"
    if [ "$PRINT_ONLY" -eq 1 ]; then
        error "--print: not a git repository (pass a repo, or drop --print)"
    fi
    read -rp "  Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    echo ""
fi

# ---------------------------------------------------------------------------
# Claude Keychain credentials (macOS only)
# ---------------------------------------------------------------------------
# On macOS the Claude OAuth token lives in the Keychain, not in `~/.claude`, so
# copying that directory leaves the container on "Not logged in · Please run
# /login". Materialise the same `.credentials.json` Claude Code writes on Linux.
#
# The secret is piped through stdin: never written to a host temp file, and never
# placed in argv where `ps` would expose it. Same approach the benchmark uses.
# --print mode skips the lookup so it never triggers a Keychain access prompt.
CLAUDE_CREDS=""
if [ "$PRINT_ONLY" -eq 0 ] && [ "$(uname -s)" = "Darwin" ] && [ ! -f "${HOME}/.claude/.credentials.json" ]; then
    CLAUDE_CREDS="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
    if [ -z "$CLAUDE_CREDS" ]; then
        info "No Claude credentials found — the Keychain lookup failed (you may need"
        info "to allow access when prompted). Set ANTHROPIC_API_KEY, or the agent"
        info "inside the sandbox will report 'Not logged in'."
    fi
fi

# ---------------------------------------------------------------------------
# Compose-mode helpers
# ---------------------------------------------------------------------------

# Quote a value as a double-quoted YAML scalar (escapes backslash and quote).
yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Render the generated override: staged host paths (the same set the native
# mode mounts, with the same existence conditions) plus user extra mounts.
gen_override() {
    local out="$1"
    local lines=""
    local i
    if [ -d "${HOME}/.claude" ]; then
        lines="${lines}      - $(yaml_quote "${HOME}/.claude:/claude-host:ro")"$'\n'
    fi
    if [ -f "${HOME}/.claude.json" ]; then
        lines="${lines}      - $(yaml_quote "${HOME}/.claude.json:/claude-host.json:ro")"$'\n'
    fi
    if [ -f "${HOME}/.config/agtx/config.toml" ]; then
        lines="${lines}      - $(yaml_quote "${HOME}/.config/agtx/config.toml:/agtx-host-config.toml:ro")"$'\n'
    fi
    if [ -d "${HOME}/.config/agtx/plugins" ]; then
        lines="${lines}      - $(yaml_quote "${HOME}/.config/agtx/plugins:/agtx-host-plugins:ro")"$'\n'
    fi
    if [ -d "${HOME}/.config/opencode" ]; then
        lines="${lines}      - $(yaml_quote "${HOME}/.config/opencode:/opencode-host:ro")"$'\n'
    fi
    _i=0
    while [ "$_i" -lt "${#M_SRC[@]}" ]; do
        lines="${lines}      - $(yaml_quote "${M_SRC[$_i]}:${M_DST[$_i]}:${M_MODE[$_i]}")"$'\n'
        _i=$((_i + 1))
    done
    {
        echo "# Generated by sandbox.sh on every run — do not edit."
        if [ -n "$lines" ]; then
            echo "services:"
            echo "  agtx:"
            echo "    volumes:"
            printf '%s' "$lines"
        else
            # A compose file must not be empty; an empty services map is valid.
            echo "services: {}"
        fi
    } > "$out"
}

# ---------------------------------------------------------------------------
# --print: emit the exact commands, then stop
# ---------------------------------------------------------------------------

if [ "$PRINT_ONLY" -eq 1 ]; then
    echo "# agtx sandbox --print"
    echo "# runtime: $CR"
    if [ "$COMPOSE_MODE" -eq 1 ]; then
        TMPD="$(mktemp -d)"
        trap 'rm -rf "$TMPD"' EXIT
        GEN_OVERRIDE="$TMPD/agtx-sandbox.generated.yaml"
        gen_override "$GEN_OVERRIDE"
        _cf=(-f "$BASE_COMPOSE" -f "$GEN_OVERRIDE")
        if [ -n "$USER_OVERRIDE_FILE" ]; then
            _cf+=(-f "$USER_OVERRIDE_FILE")
            echo "# user:      $USER_OVERRIDE_FILE"
        fi
        echo "# base:      $BASE_COMPOSE"
        echo "# generated override:"
        cat "$GEN_OVERRIDE"
        echo "# commands:"
        echo "${CR} compose ${_cf[*]} build"
        echo "${CR} compose ${_cf[*]} up -d"
        echo "${CR} ps -aq --filter label=com.docker.compose.service=agtx --filter status=running"
        if [ "$(uname -s)" = "Darwin" ]; then
            echo "# (runtime only, if a Keychain credential is present): ${CR} compose ${_cf[*]} exec -T agtx /bin/bash -c 'umask 077 && cat > /home/sandbox/.claude/.credentials.json'"
        fi
        echo "${CR} attach <CID>"
        echo "${CR} compose ${_cf[*]} down --remove-orphans"
    else
        echo "${CR} ${RUN_ARGS[*]}"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

info "Building image..."
if [ "$COMPOSE_MODE" -eq 1 ]; then
    # Host UID/GID so files created in the container are owned correctly; the
    # base compose file interpolates them as build args.
    SANDBOX_PROJECT="$PROJECT"
    SANDBOX_UID="$(id -u)"
    SANDBOX_GID="$(id -g)"
    SANDBOX_USERNS_MODE="$USERNS_MODE"
    SANDBOX_NETWORK_MODE="$NET_MODE"
    export SANDBOX_PROJECT SANDBOX_UID SANDBOX_GID SANDBOX_USERNS_MODE SANDBOX_NETWORK_MODE

    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT
    GEN_OVERRIDE="$TMPD/agtx-sandbox.generated.yaml"
    gen_override "$GEN_OVERRIDE"

    COMPOSE_FILES=(-f "$BASE_COMPOSE" -f "$GEN_OVERRIDE")
    if [ -n "$USER_OVERRIDE_FILE" ]; then COMPOSE_FILES+=(-f "$USER_OVERRIDE_FILE"); fi

    "${COMPOSE[@]}" "${COMPOSE_FILES[@]}" build
else
    "$CR" build -q \
        --build-arg UID="$(id -u)" \
        --build-arg GID="$(id -g)" \
        -t agtx-sandbox \
        "$DOCKER_DIR"
fi

success "Image ready"
echo ""

# ---------------------------------------------------------------------------
# Launch, seed, attach
# ---------------------------------------------------------------------------

if [ "$COMPOSE_MODE" -eq 1 ]; then
    # Same lifecycle as the native path (detached start → seed credential →
    # attach), expressed through compose. Attach goes through the native
    # runtime (docker/podman attach) on the container ID — both compose
    # implementations create ordinary containers, and this avoids depending on
    # each implementation's own attach support. `down` afterwards removes the
    # container and network but keeps the named 'agtx-data' volume, exactly
    # like native `run --rm` + named volume.
    "${COMPOSE[@]}" "${COMPOSE_FILES[@]}" up -d

    CID=""
    for _try in 1 2 3 4 5; do
        CID="$("$CR" ps -aq --filter "label=com.docker.compose.service=agtx" --filter "status=running" | head -n1 || true)"
        if [ -n "$CID" ]; then break; fi
        sleep 1
    done
    if [ -z "$CID" ]; then
        error "sandbox container did not start — check: ${CR} compose ${COMPOSE_FILES[*]} logs"
    fi

    if [ -n "$CLAUDE_CREDS" ]; then
        printf '%s' "$CLAUDE_CREDS" | "${COMPOSE[@]}" "${COMPOSE_FILES[@]}" exec -T agtx \
            /bin/bash -c 'umask 077 && cat > /home/sandbox/.claude/.credentials.json'
        unset CLAUDE_CREDS
    fi

    rc=0
    "$CR" attach "$CID" || rc=$?
    unset CLAUDE_CREDS
    "${COMPOSE[@]}" "${COMPOSE_FILES[@]}" down --remove-orphans >/dev/null 2>&1 || true
    exit "$rc"
fi

# Started detached so the credential can be planted before any agent launches,
# then attached so the TUI behaves exactly as before. `--rm` still cleans up on
# exit, and `attach` returns the container's exit code.
CID=$("$CR" "${RUN_ARGS[@]}")

if [ -n "$CLAUDE_CREDS" ]; then
    printf '%s' "$CLAUDE_CREDS" | "$CR" exec -i "$CID" \
        /bin/bash -c 'umask 077 && cat > /home/sandbox/.claude/.credentials.json'
    unset CLAUDE_CREDS
fi

exec "$CR" attach "$CID"
