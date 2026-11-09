# agtx container

Run agtx in a container (Docker or Podman, including rootless Podman). Two
launchers with two modes — the container definitions themselves live in two
self-contained files: `compose.yaml` (sandbox) and `compose.runtime.yaml`
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
`localhost:11434`), the container must reach the host's loopback:

- **Host networking is on by default** (Linux), so this just works.
- On macOS Podman cannot do host networking, so it falls back to bridge and the
  entrypoint rewrites the loopback hosts in the container's config (the staged
  copy in sandbox mode, the real config in runtime mode) to whichever host
  address it can actually reach (slirp gateway, `host.docker.internal`, or the
  bridge gateway). Your real config is never touched in runtime mode.
- Override either way: `AGTX_HOST_NETWORK=1` forces host networking on, `=0` off.

## Runtime (no sandbox)

Not a jail — a way to *run* agtx. Your real `~/.config/agtx`, `~/.config/opencode`,
`~/.claude`, and `~/.claude.json` are mounted **writable**, so agtx writes config,
status, and updates straight to the host, like a local install. The OpenCode
config supplies its provider/model selection. Same least-privilege caps.

```bash
# On a project, writing config/state back to the host
./docker/runtime.sh path/to/your-project
```

Runtime mode mounts the project under its own directory name inside the container
(`/home/sandbox/workspaces/<project>`), so agtx derives the real project name and
the AGTX board shows it rather than the sandbox's generic `workspace`. Sandbox
mode keeps the generic name because its state is isolated.

**Switching between projects.** agtx lists every project it has ever seen but
silently skips one whose path does not exist — so in the container, only mounted
projects are reachable in the sidebar. By default only the launched project is
mounted. To make a group of projects switchable at once, set `PROJECTS_DIR`
(in `docker/.env` or the environment) to the directory that *contains* them as
direct children; runtime mode then mounts that whole root at
`/home/sandbox/workspaces`, so each project appears at
`/home/sandbox/workspaces/<name>`. Leave `PROJECTS_DIR` unset to keep mounting
only the launched project.

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
3. Run `./docker/sandbox.sh` or `./docker/runtime.sh` as usual — it uses
   `compose.custom.yaml` when present and reads its mode (`AGTX_MODE`) and
   container name from it.

Delete `docker/compose.custom.yaml` to go back to the defaults.

> Note: both launchers pre-create the host config paths they mount (e.g.
> `~/.claude`, `~/.config/agtx`, `~/.config/opencode`) as *your host user* if
> they do not exist yet, so a bind mount never auto-creates a root-owned
> directory. An empty one simply stages as a no-op at startup (sandbox) / mounts
> as-is (runtime).

## Details

- **Runtime:** docker when installed, else podman. Set `AGTX_CONTAINER_RUNTIME=docker|podman` to force one. The image builds on first run, then is cached.
- **Launch a definition directly** (skip the launcher):
  ```bash
  # sandbox
  PROJECT=/path/to/project docker compose -f docker/compose.yaml up -d
  PROJECT=/path/to/project docker compose -f docker/compose.yaml attach sandbox

  # runtime (WORKSPACE_MOUNT is normally computed by the launcher; set it here)
  WORKSPACE_MOUNT=/path/to/project:/home/sandbox/workspaces/project \
      docker compose -f docker/compose.runtime.yaml up -d
  WORKSPACE_MOUNT=/path/to/project:/home/sandbox/workspaces/project \
      docker compose -f docker/compose.runtime.yaml attach agtx-runtime

  # tear down afterwards
  WORKSPACE_MOUNT=/path/to/project:/home/sandbox/workspaces/project \
      docker compose -f docker/compose.runtime.yaml down
  ```

  > A foreground `up` is not enough for the TUI: compose's foreground mode
  > tails the container's logs but never attaches stdin, so agtx runs without
  > a keyboard. That is why the examples detach first and then attach. With
  > Podman the attach step is the runtime-native command, because
  > `podman-compose` has no `attach` subcommand:
  > `podman attach agtx-runtime` (or `agtx-sandbox`).
- **Files:** `compose.yaml` (sandbox), `compose.runtime.yaml` (runtime), each
  self-contained with reasonable defaults + commented optional settings;
  `compose.keepid.yaml` (rootless-Podman-only `user: "0"` override, added
  automatically); `compose.custom.yaml` (optional, gitignored — your edited copy
  of a default); `docker/.env` (optional, gitignored — host-specific launcher
  overrides such as `PROJECTS_DIR`; see `docker/.env.example`); `docker/common.sh`
  (shared plumbing sourced by both launchers — logging, runtime detection, `.env`
  loading, image build, rootless-Podman keep-id, TUI runner); `docker/sandbox.sh`
  (the jail launcher); `docker/runtime.sh` (the portable-install launcher);
  `entrypoint.sh` (startup config); `Dockerfile`.
