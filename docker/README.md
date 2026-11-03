# agtx container

Run agtx in a container (Docker or Podman, including rootless Podman). One
launcher — `sandbox.sh` — with two modes, and the container itself defined in
`compose.yaml` / `compose.runtime.yaml`.

> All commands below assume you are in the repository root.

## Sandbox (default)

Isolated: agtx's state lives in a named volume and your host settings are staged
read-only, so nothing the agent does can reach the host.

```bash
# On a project — or from inside the project directory
./docker/sandbox.sh path/to/your-project
```

## Local models (host networking)

If your agent's provider is a model hosted *on this machine* (e.g. Ollama on
`localhost:11434` in OpenCode's config), the sandbox must reach the host's
loopback:

- **Host networking is on by default** (Linux), so this just works.
- On macOS Podman cannot do host networking, so it falls back to bridge and the
  entrypoint rewrites the loopback hosts in the *copied* OpenCode config to
  whichever host address it can actually reach (slirp gateway,
  `host.docker.internal`, or the bridge gateway). Your real config is never
  touched.
- Override either way: `AGTX_HOST_NETWORK=1` forces host networking on, `=0` off.

## Runtime (no sandbox)

Not a jail — a way to *run* agtx. Your real `~/.config/agtx`, `~/.config/opencode`,
`~/.claude`, and `~/.claude.json` are mounted **writable**, so agtx writes config,
status, and updates straight to the host, like a local install. The OpenCode
config supplies its provider/model selection. Same least-privilege caps.

```bash
# On a project, writing config/state back to the host
AGTX_RUNTIME=1 ./docker/sandbox.sh path/to/your-project
```

Runtime mode mounts the project under its own directory name inside the container
(`/home/sandbox/workspaces/<project>`), so agtx derives the real project name and
the AGTX board shows it rather than the sandbox's generic `workspace`. Sandbox
mode keeps the generic name because its state is isolated.

The container is named `agtx-runtime` in this mode (sandbox mode uses
`agtx-sandbox`), so `docker inspect` / `podman inspect` and `stop` address the
right one.

## Details

- **Runtime:** docker when installed, else podman. Set `AGTX_CONTAINER_RUNTIME=docker|podman` to force one. The image builds on first run, then is cached.
- **Launch a definition directly** (skip `sandbox.sh`):
  ```bash
  # sandbox
  PROJECT=/path/to/project docker compose -f docker/compose.yaml up -d
  PROJECT=/path/to/project docker compose -f docker/compose.yaml attach sandbox

  # runtime
  PROJECT=/path/to/project PROJECT_NAME=$(basename /path/to/project) \
    docker compose -f docker/compose.runtime.yaml up -d
  PROJECT=/path/to/project PROJECT_NAME=$(basename /path/to/project) \
    docker compose -f docker/compose.runtime.yaml attach sandbox

  # tear down afterwards
  PROJECT=/path/to/project docker compose -f docker/compose.yaml down
  ```
- **Files:** `compose.yaml` (sandbox) + `compose.<asset>.yaml` fragments (optional host-asset mounts, host networking, Podman `keep-id`); `compose.runtime.yaml` (runtime); `sandbox.sh` (launcher); `entrypoint.sh` (startup config); `Dockerfile`.
