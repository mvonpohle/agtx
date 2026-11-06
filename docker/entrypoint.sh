#!/bin/bash
set -e

# Runtime mode: the container's config IS the host's real config (mounted
# writable), so there's nothing to pre-configure — just run agtx. Sandbox mode
# (default) falls through to the staging below.
if [ "${AGTX_MODE:-sandbox}" = "runtime" ]; then
    exec "$@"
fi

# Sandbox mode: stage a disposable copy of the host config into the sandbox
# home. Runs as the unprivileged sandbox user, which carries DAC_OVERRIDE so it
# can read the host's own (typically 700, host-owned) config. Staged files are
# owned by sandbox so the agent can read/write them.

# Copy host ~/.claude into the writable home (host dir is mounted ro at
# /claude-host so Claude can read without writing back to the host).
if [ -d /claude-host ]; then
    cp -rp /claude-host/. /home/sandbox/.claude/ 2>/dev/null || true
fi

# Copy the host's ~/.claude.json (onboarding state + per-directory trust map) so
# Claude doesn't reopen its theme picker.
if [ -f /claude-host.json ]; then
    cp /claude-host.json /home/sandbox/.claude.json 2>/dev/null || true
    chmod u+w /home/sandbox/.claude.json 2>/dev/null || true
fi

# Copy the host's OpenCode global config (provider + model) — without it a fresh
# container has no provider. Only the config file is worth copying; the plugin
# runtime (node_modules) is host-specific.
if [ -d /opencode-host ]; then
    mkdir -p /home/sandbox/.config/opencode
    cp -f /opencode-host/opencode.json  /home/sandbox/.config/opencode/ 2>/dev/null || true
    cp -f /opencode-host/opencode.jsonc /home/sandbox/.config/opencode/ 2>/dev/null || true
    cp -f /opencode-host/opencode.json5 /home/sandbox/.config/opencode/ 2>/dev/null || true
fi

# On bridge networking (e.g. podman on macOS) the container's localhost is not
# the host's, so a provider pointed at a local model is unreachable. Discover the
# host as seen from here and rewrite the loopback hosts in the COPIED config
# (any port/provider). The host's real config is never touched.
if [ "${SANDBOX_NET_MODE:-bridge}" != "host" ] && [ -d /opencode-host ]; then
    oc_cfg=/home/sandbox/.config/opencode
    oc_refs=$(cat "$oc_cfg"/opencode.json* 2>/dev/null | grep -ohE 'https?://(localhost|127\.0\.0\.1)(:[0-9]+)?' | sort -u)
    if [ -n "$oc_refs" ]; then
        # Probe on the first referenced port; all local services share the host.
        oc_port=$(printf '%s\n' "$oc_refs" | grep -oE ':[0-9]+$' | head -n1 | tr -d ':')
        [ -n "$oc_port" ] || oc_port=11434
        # No iproute2 in the image, so decode /proc/net/route for the gateway.
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
            # --noproxy '*': probe directly, or a http_proxy env would answer
            # every probe and fake a reachable host.
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
            # Make the rewritten host bypass the agent's http_proxy too.
            export no_proxy="$oc_host${no_proxy:+,$no_proxy}"
            export NO_PROXY="$oc_host${NO_PROXY:+,$NO_PROXY}"
            echo "opencode: local model host rewritten for bridge networking: $oc_refs -> $oc_host"
        else
            echo "warning: local model host unreachable from the sandbox ($oc_refs) — is Ollama running on a non-loopback interface?"
        fi
    fi
fi

# Trust the workspace for Claude. Trust records are path-keyed and the project
# is mounted at a path the host never used, so the copied map never matches it.
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

# Drop empty auth keys from the copied settings.json: that `env` block outranks
# process env, so a leftover ANTHROPIC_AUTH_TOKEN:"" would shadow the planted
# credentials and a real API key, making the agent report "Not logged in".
# Host file untouched; only the container copy is edited.
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

# Pre-accept the bypass permission prompt: we're in an isolated container with
# no host access beyond the project dir.
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

# Copy the host's global agtx settings + plugins (mounted ro).
[ -f /agtx-host-config.toml ] && cp -f /agtx-host-config.toml /home/sandbox/.config/agtx/config.toml 2>/dev/null || true
if [ -d /agtx-host-plugins ]; then
    rm -rf /home/sandbox/.config/agtx/plugins
    cp -r /agtx-host-plugins /home/sandbox/.config/agtx/plugins 2>/dev/null || true
fi

# Turn on auto_trust (no human at the board to answer trust prompts).
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
