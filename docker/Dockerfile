FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Ubuntu's OpenSSL auto-enables FIPS when the host kernel is in FIPS mode, but
# this image ships no FIPS module, so digests fail there. No-op otherwise.
ENV OPENSSL_FORCE_FIPS_MODE=0

ARG NODE_MAJOR=22

# System deps + Node.js via NodeSource (handles arch automatically)
RUN apt-get update && apt-get install -y \
    curl git tmux ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install OpenCode
RUN npm install -g opencode-ai

# Install agtx
RUN curl -fsSL https://raw.githubusercontent.com/fynnfluegge/agtx/main/install.sh \
    | AGTX_INSTALL_DIR=/usr/local/bin bash

# Skip the in-image update check: the user can't apply it from here, and every
# start would burn a request against the shared-IP GitHub rate limit.
ENV AGTX_NO_UPDATE_CHECK=1

# Non-root user; UID/GID match the host so bind-mounted files stay owned
ARG UID=1000
ARG GID=1000
# `groupadd -g` fails when the GID is taken (GID 20 is `dialout` on Ubuntu, and
# 20 is the default GID on macOS), so reuse the existing group — only the UID
# ownership matters for the bind mounts.
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd -g "${GID}" sandbox 2>/dev/null || true && \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash sandbox

COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
# Explicit 755: the non-root sandbox user must read (shebang) as well as exec
# the script, which `chmod +x` on a 700 source wouldn't grant.
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Create agtx dirs so named volume mounts inherit correct ownership.
# Group-writable (not user-owned): rootless builds can't setuid to huge host UIDs.
RUN mkdir -p /home/sandbox/.config/agtx /home/sandbox/.claude && \
    chgrp -R "${GID}" /home/sandbox && chmod -R g+w /home/sandbox

USER sandbox
WORKDIR /home/sandbox

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["agtx"]
