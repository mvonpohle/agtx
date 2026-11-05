# agtx container

Run agtx in a container (Docker or Podman, including rootless Podman). One
launcher — `sandbox.sh` — with two modes, and the container itself defined in
two self-contained files: `compose.yaml` (sandbox) and `compose.runtime.yaml`
(runtime). Each carries reasonable defaults with commented-out optional
settings; to make your own tweaks, copy one to the gitignored
`compose.custom.yaml` (see [Customize](#customize)).

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

## Customize

Both definitions ship with reasonable defaults and commented-out optional
settings (ports, restart policy, image override, extra env). To make your own
tweaks that survive repo updates and never pollute the repo:

1. Copy the definition you use to `docker/compose.custom.yaml` (already
   gitignored):
   ```bash
   cp docker/compose.yaml docker/compose.custom.yaml        # sandbox
   # or: cp docker/compose.runtime.yaml docker/compose.custom.yaml   # runtime
   ```
2. Edit `docker/compose.custom.yaml` freely.
3. Run `./docker/sandbox.sh` as usual — it uses `compose.custom.yaml` when
   present and reads its mode (`AGTX_MODE`) and container name from it.

Delete `docker/compose.custom.yaml` to go back to the defaults.

> Note: `sandbox.sh` pre-creates the host config paths it mounts (e.g.
> `~/.claude`, `~/.config/agtx`, `~/.config/opencode`) as *your host user* if
> they do not exist yet, so a bind mount never auto-creates a root-owned
> directory. An empty one simply stages as a no-op at startup.

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
- **Files:** `compose.yaml` (sandbox) and `compose.runtime.yaml` (runtime), each self-contained with reasonable defaults + commented optional settings; `compose.keepid.yaml` (rootless-Podman-only `userns_mode: keep-id`, added automatically); `compose.custom.yaml` (optional, gitignored — your edited copy of a default); `sandbox.sh` (launcher); `entrypoint.sh` (startup config); `Dockerfile`.
