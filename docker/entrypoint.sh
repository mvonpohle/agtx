#!/bin/bash
set -e

# Copy host ~/.claude credentials into the writable sandbox home at startup.
# The host directory is mounted read-only at /claude-host so Claude Code can
# read credentials without the container ever writing back to the host.
if [ -d /claude-host ]; then
    cp -rp /claude-host/. /home/sandbox/.claude/ 2>/dev/null || true
fi

# Copy the host's ~/.claude.json snapshot: onboarding state (so Claude does not
# open on its theme picker) plus the per-directory trust map. Mounted read-only,
# copied so the container can write to it.
if [ -f /claude-host.json ]; then
    cp /claude-host.json /home/sandbox/.claude.json 2>/dev/null || true
    chmod u+w /home/sandbox/.claude.json 2>/dev/null || true
fi

# Copy the host's OpenCode global config (provider + model selection) into the
# writable sandbox home, the same way ~/.claude is copied above. Only the config
# file is worth copying — the plugin runtime (node_modules) OpenCode manages
# itself and is host-specific. Without this a fresh container has no provider
# and opens on a "no provider" state.
if [ -d /opencode-host ]; then
    mkdir -p /home/sandbox/.config/opencode
    cp -f /opencode-host/opencode.json  /home/sandbox/.config/opencode/ 2>/dev/null || true
    cp -f /opencode-host/opencode.jsonc /home/sandbox/.config/opencode/ 2>/dev/null || true
    cp -f /opencode-host/opencode.json5 /home/sandbox/.config/opencode/ 2>/dev/null || true
fi

# On bridge networking (e.g. podman on macOS, where --network host is
# unavailable) the container's localhost is not the host's: a provider pointed
# at a local model (e.g. Ollama on localhost:11434) is unreachable as
# configured. Discover the host as seen from here — the slirp gateway, Docker's
# host alias, or the bridge gateway — and rewrite the loopback hosts in the
# COPIED config (any port, any provider). The host's real config is never
# touched; if nothing responds the config is left as-is and we warn.
if [ "${SANDBOX_NET_MODE:-bridge}" != "host" ] && [ -d /opencode-host ]; then
    oc_cfg=/home/sandbox/.config/opencode
    oc_refs=$(cat "$oc_cfg"/opencode.json* 2>/dev/null | grep -ohE 'https?://(localhost|127\.0\.0\.1)(:[0-9]+)?' | sort -u)
    if [ -n "$oc_refs" ]; then
        # Probe on the first referenced port; all local services share the host.
        oc_port=$(printf '%s\n' "$oc_refs" | grep -oE ':[0-9]+$' | head -n1 | tr -d ':')
        [ -n "$oc_port" ] || oc_port=11434
        # Default gateway. No iproute2 in the image, so decode /proc/net/route.
        def_gw=$(node -e '
            try {
                const lines = require("fs").readFileSync("/proc/net/route", "utf8").trim().split("\n").slice(1);
                for (const line of lines) {
                    const c = line.trim().split(/\s+/);
                    if (c[1] === "00000000") {
                        console.log(("00000000" + c[2]).slice(-8).match(/../g).reverse().map(x => parseInt(x, 16)).join("."));
                        break;
                    }
                }
            } catch (e) {}
        ' 2>/dev/null)
        oc_host=""
        for cand in 10.0.2.2 host.docker.internal 172.17.0.1 ${def_gw:-}; do
            [ -n "$cand" ] || continue
            # --noproxy '*': probe directly. On proxied networks (corporate HPC)
            # an http_proxy env var would answer every probe for the proxy's own
            # error page and fake a reachable host.
            if curl -s --max-time 1 --noproxy '*' -o /dev/null "http://$cand:$oc_port/"; then
                oc_host=$cand
                break
            fi
        done
        if [ -n "$oc_host" ]; then
            for f in "$oc_cfg"/opencode.json "$oc_cfg"/opencode.jsonc "$oc_cfg"/opencode.json5; do
                [ -f "$f" ] || continue
                sed -i -E "s#(https?)://(localhost|127\.0\.0\.1)(:[0-9]+)?#\1://$oc_host\3#g" "$f"
            done
            # The agent's own HTTP client honors http_proxy too; make sure the
            # rewritten host bypasses it, or the model traffic still goes to the
            # proxy instead of the host.
            export no_proxy="$oc_host${no_proxy:+,$no_proxy}"
            export NO_PROXY="$oc_host${NO_PROXY:+,$NO_PROXY}"
            echo "opencode: local model host rewritten for bridge networking: $oc_refs -> $oc_host"
        else
            echo "warning: local model host unreachable from the sandbox ($oc_refs) — is Ollama running on a non-loopback interface?"
        fi
    fi
fi

# Trust the workspace for Claude. Trust records are path-keyed and the project is
# mounted at a path the host never used, so the copied map above never matches it.
# Appropriate here for the same reason as the bypass pre-accept: an isolated,
# disposable container holding nothing but the project.
node -e "
    const fs = require('fs');
    const p = '/home/sandbox/.claude.json';
    let d = {};
    try { d = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) {}
    d.projects = d.projects || {};
    d.projects['/home/sandbox/workspace'] = d.projects['/home/sandbox/workspace'] || {};
    d.projects['/home/sandbox/workspace'].hasTrustDialogAccepted = true;
    fs.writeFileSync(p, JSON.stringify(d, null, 2));
"

# Drop empty auth keys from the copied settings.json. That `env` block outranks
# process env, so an `ANTHROPIC_AUTH_TOKEN: ""` left over from a proxy setup
# shadows *both* the Keychain credentials planted above and a real
# ANTHROPIC_API_KEY — and the agent reports "Not logged in" with valid auth
# available. The host file is untouched; only the container's copy is edited.
settings_env=/home/sandbox/.claude/settings.json
if [ -f "$settings_env" ]; then
    node -e "
        const fs = require('fs');
        const p = '$settings_env';
        let d;
        try { d = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { process.exit(0); }
        const env = d.env;
        if (env && typeof env === 'object') {
            const dropped = Object.keys(env).filter((k) => env[k] === '');
            for (const k of dropped) delete env[k];
            if (dropped.length) {
                fs.writeFileSync(p, JSON.stringify(d, null, 2));
                console.log('dropped empty env keys: ' + dropped.join(', '));
            }
        }
    "
fi

# Pre-accept the bypass permissions prompt — appropriate because we are inside
# an isolated container with no access to the host filesystem beyond the
# project directory.
settings=/home/sandbox/.claude/settings.json
if [ -f "$settings" ]; then
    node -e "
        const fs = require('fs');
        const s = JSON.parse(fs.readFileSync('$settings', 'utf8'));
        s.skipDangerousModePermissionPrompt = true;
        fs.writeFileSync('$settings', JSON.stringify(s, null, 2));
    "
else
    echo '{"skipDangerousModePermissionPrompt":true}' > "$settings"
fi

# Copy the host's global agtx settings into the writable sandbox home.
# Mounted read-only so the container never writes back to the host.
[ -f /agtx-host-config.toml ] && cp -f /agtx-host-config.toml /home/sandbox/.config/agtx/config.toml 2>/dev/null || true
if [ -d /agtx-host-plugins ]; then
    rm -rf /home/sandbox/.config/agtx/plugins
    cp -r /agtx-host-plugins /home/sandbox/.config/agtx/plugins 2>/dev/null || true
fi

# Turn on auto_trust inside the sandbox (no human at the board to answer trust
# prompts). Skipped when the config dir isn't writable.
if [ -w /home/sandbox/.config/agtx ]; then
    mkdir -p /home/sandbox/.config/agtx
    agtx_config=/home/sandbox/.config/agtx/config.toml
    if [ -f "$agtx_config" ]; then
        grep -q '^auto_trust' "$agtx_config" || echo 'auto_trust = true' >> "$agtx_config"
    else
        echo 'auto_trust = true' > "$agtx_config"
    fi
fi

exec "$@"
