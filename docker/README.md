# agtx container

Run agtx in Docker or Podman (including rootless). Two modes:

- **Sandbox** (default) — isolated. agtx state lives in a named volume and your
  host settings are staged read-only, so nothing the agent does reaches the host.
- **Runtime** — not a jail. Your host config and state (`~/.config/agtx`,
  `~/.config/opencode`, `~/.claude`, `~/.claude.json`) are mounted writable, so
  agtx writes config, status, and updates straight to the host.

All commands assume you are in the repository root.

## Run

```bash
# Sandbox (default)
./docker/sandbox.sh path/to/your-project

# Runtime
AGTX_RUNTIME=1 ./docker/sandbox.sh path/to/your-project
```

The launcher uses docker when installed, else podman. Force one with
`AGTX_CONTAINER_RUNTIME=docker|podman`. The image builds on first run, then is cached.
You can also launch a compose file directly; each one documents its `docker compose`
command in its header.

## Local models

If your provider runs on this machine (e.g. Ollama on `localhost:11434`), the
sandbox must reach the host's loopback.

- **Linux:** host networking is on by default, so this works.
- **macOS (Podman):** host networking is unavailable, so the entrypoint rewrites
  the loopback hosts in the copied OpenCode config to a reachable host address.
  Your real config is untouched.

Override with `AGTX_HOST_NETWORK=1` (on) or `=0` (off).

## Runtime mode

The project mounts under its own name (`/home/sandbox/workspaces/<project>`) so
agtx derives the real project name and the board shows it. The container is named
`agtx-runtime` (sandbox mode uses `agtx-sandbox`) so `inspect` and `stop` target
the right one.

## Customize

Copy the definition you use to `docker/compose.custom.yaml` (gitignored) and
edit it. `sandbox.sh` uses that file when present, reading its mode (`AGTX_MODE`)
and container name from it. Delete it to return to the defaults.

```bash
cp docker/compose.yaml docker/compose.custom.yaml        # sandbox
# or: cp docker/compose.runtime.yaml docker/compose.custom.yaml   # runtime
```

The definitions include commented optional settings (ports, restart policy, image
override, extra env).

## Files

- `sandbox.sh` — launcher
- `compose.yaml` — sandbox definition
- `compose.runtime.yaml` — runtime definition
- `compose.keepid.yaml` — rootless-Podman `userns_mode: keep-id`, added automatically
- `compose.custom.yaml` — optional gitignored override (not committed)
- `entrypoint.sh` — startup config
- `Dockerfile`

> `sandbox.sh` pre-creates any missing host config paths as your host user, so a
> bind mount never creates a root-owned directory. An empty one stages as a no-op.
