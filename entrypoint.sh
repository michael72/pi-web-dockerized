#!/bin/bash
set -euo pipefail

# This script runs as root and handles UID/GID mapping before switching to coder user

# Fix Docker socket permissions if mounted from host
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)

    # Create or use existing group with matching GID
    if ! getent group "$DOCKER_SOCK_GID" >/dev/null 2>&1; then
        groupadd -g "$DOCKER_SOCK_GID" docker_host 2>/dev/null || true
    fi

    # Add coder user to the docker socket's group for access
    usermod -aG "$DOCKER_SOCK_GID" coder 2>/dev/null || true
fi

# Get target UID/GID from environment (default to 1000)
TARGET_UID=${HOST_UID:-1000}
TARGET_GID=${HOST_GID:-1000}

# Get current coder user UID/GID
CURRENT_UID=$(id -u coder)
CURRENT_GID=$(id -g coder)

# Update UID/GID if they don't match
if [ "$TARGET_UID" != "$CURRENT_UID" ] || [ "$TARGET_GID" != "$CURRENT_GID" ]; then
    echo "Adjusting coder user UID:GID from $CURRENT_UID:$CURRENT_GID to $TARGET_UID:$TARGET_GID"

    # Update group ID if needed
    if [ "$TARGET_GID" != "$CURRENT_GID" ]; then
        groupmod -g "$TARGET_GID" coder 2>/dev/null || true
    fi

    # Update user ID if needed
    if [ "$TARGET_UID" != "$CURRENT_UID" ]; then
        usermod -u "$TARGET_UID" coder 2>/dev/null || true
    fi

    # Fix ownership of essential home directory contents only
    # Avoid full recursive chown on NVM/SDKMAN trees which can be very slow
    echo "Fixing home directory permissions..."
    chown "$TARGET_UID:$TARGET_GID" /home/coder 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.config 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.local 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.cache 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.npm 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.gradle 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.m2 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.pi 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.pi-web 2>/dev/null || true
    # NVM and SDKMAN: only fix top-level ownership, not deeply nested files
    chown "$TARGET_UID:$TARGET_GID" /home/coder/.nvm 2>/dev/null || true
    chown "$TARGET_UID:$TARGET_GID" /home/coder/.sdkman 2>/dev/null || true
fi

# NOTE: We do NOT change ownership of the project directory
# The project mount is a host bind-mount and should maintain host permissions
# Pi runs as the host user (via UID/GID mapping) so it already has the right permissions

# Resolve the project working directory (set by pi-web-dockerized.sh)
# Exported so the shells started below read it from the environment instead of
# having the path spliced into their command line.
export WORKDIR="${PI_WORKDIR:-/}"

# Set HOME explicitly to ensure it points to /home/coder
export HOME=/home/coder
export USER=coder

# Source NVM and SDKMAN to make Node.js and Java available
export NVM_DIR="/home/coder/.nvm"

# Runs a command as the mapped host user with Node.js available.
# Usage: as_host_user <command...>
as_host_user() {
    setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
        bash -c "source \$NVM_DIR/nvm.sh && \"\$@\"" -- "$@"
}

# ---------------------------------------------------------------------------
# Pi packages (idempotent)
#
# PI_PACKAGES is a space-separated list of 'npm:' / 'git:' sources chosen with
# setup.sh. Pi packages bundle extensions, skills, prompt templates and themes;
# for example pi-matt-pocock-skills (Matt Pocock's skills plus a subagent tool and
# five agent definitions) and graphify-pi (graph-first guidance and /graphify).
#
# They are installed into ~/.pi/agent — the host-persisted agent directory — so the
# download happens once, not on every launch. Only sources missing from
# settings.json are installed; removing one from the config does not uninstall it
# (use './pi-web-dockerized.sh pkg remove <source>').
# ---------------------------------------------------------------------------
if [ -n "${PI_PACKAGES:-}" ] && command -v pi >/dev/null 2>&1; then
    PI_SETTINGS_FILE="/home/coder/.pi/agent/settings.json"

    for pi_source in $PI_PACKAGES; do
        # Defence in depth: the wrapper validates these already
        if ! [[ "$pi_source" =~ ^(npm|git):[A-Za-z0-9@/._:+~-]+$ ]]; then
            echo "Pi packages: ignoring invalid source '$pi_source'"
            continue
        fi

        # settings.json lists a package either as a string or as {"source": ...}
        if [ -f "$PI_SETTINGS_FILE" ] && jq -e --arg s "$pi_source" \
            '[.packages[]? | if type == "object" then .source else . end] | index($s) != null' \
            "$PI_SETTINGS_FILE" >/dev/null 2>&1; then
            continue
        fi

        echo "Pi packages: installing $pi_source..."
        as_host_user pi install "$pi_source" </dev/null || \
            echo "Pi packages: installing $pi_source failed (non-fatal) — run './pi-web-dockerized.sh pkg install $pi_source' to retry"
    done
fi

# ---------------------------------------------------------------------------
# Graphify: per-project knowledge graph (opt-out via setting.graphify_support=false)
#
# The 'graphify' CLI is installed in the image. What Pi sees of it is the
# graphify-pi package (installed above): it injects graph-first guidance when
# graphify-out/ exists, flags a stale graph and registers /graphify.
#
# This only builds and refreshes the graph. '--code-only' / 'update' use local AST
# extraction, so startup needs no API key and no network. '--no-label' keeps
# communities as "Community N" instead of calling an LLM to name them; run
# '/graphify label .' inside Pi once a provider is configured.
#
# Only for commands that work on a project (PI_PROJECT_SETUP=true). The graph is
# written to the project's graphify-out/ — add it to .gitignore if unwanted.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # "$1" is expanded by the inner shell, which receives the path as an argument
if [ "${GRAPHIFY_SUPPORT:-true}" = "true" ] && [ "${PI_PROJECT_SETUP:-false}" = "true" ] \
    && [ "$WORKDIR" != "/" ] && command -v graphify >/dev/null 2>&1; then
    if [ ! -f "$WORKDIR/graphify-out/graph.json" ]; then
        echo "Graphify: building initial knowledge graph..."
        as_host_user bash -c 'cd "$1" && graphify . --code-only' graphify-build "$WORKDIR" || \
            echo "Graphify: initial build failed (non-fatal) — run 'graphify . --code-only' manually"
    else
        echo "Graphify: refreshing knowledge graph (incremental update)..."
        as_host_user bash -c 'cd "$1" && graphify update .' graphify-update "$WORKDIR" || \
            echo "Graphify: update failed (non-fatal) — run 'graphify update .' manually"
    fi

    # GRAPH_REPORT.md + graph.html from the graph that was just written
    if [ -f "$WORKDIR/graphify-out/graph.json" ]; then
        as_host_user bash -c 'cd "$1" && graphify cluster-only . --no-label' graphify-report "$WORKDIR" >/dev/null || \
            echo "Graphify: report generation failed (non-fatal) — run 'graphify cluster-only . --no-label' manually"
    fi
fi

# Use setpriv to drop privileges and exec the command as the mapped user
# cd into the project working directory before executing
# The PlantUML server (pumlsrv, used by 'pumlcli') is started here, as the mapped
# user rather than root, and only when enabled; its output goes to a log file so it
# cannot garble the terminal UI.
exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
    bash -c "source \$NVM_DIR/nvm.sh && source /home/coder/.sdkman/bin/sdkman-init.sh 2>/dev/null || true && \
        if [ \"\${PLANTUML_SUPPORT:-true}\" = true ] && command -v pumlsrv-server >/dev/null 2>&1; then \
            nohup pumlsrv-server >/tmp/pumlsrv.log 2>&1 & \
        fi; \
        cd \"\$WORKDIR\" && exec \"\$@\"" \
    -- "$@"
