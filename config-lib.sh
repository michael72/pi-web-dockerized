#!/bin/bash

# config-lib.sh - Shared configuration module for pi-web-dockerized
# This file is sourced by other scripts (not executed directly)
# Provides: config parsing, docker arg building, shared volume logic, and interactive prompts

# NOTE: Do not use "set -e" here — this is a library file sourced by callers.
# Let calling scripts control their own error handling.

# ============================================
# CONSTANTS
# ============================================

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/pi-web-dockerized}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config}"

# Host-side state of the container. Kept apart from the host's own ~/.pi/agent on
# purpose: Pi's containerization guide advises against mounting it, because that
# hands the container your credentials, extensions and sessions. Override with
# setting.host_pi_config=true to share it anyway.
DATA_DIR="${PI_DOCKERIZED_DATA_DIR:-$HOME/.local/share/pi-web-dockerized}"
AGENT_DIR_PRIVATE="$DATA_DIR/agent"          # -> /home/coder/.pi/agent  (auth, settings, sessions, packages)
WEB_CONFIG_DIR="$DATA_DIR/pi-web/config"     # -> /home/coder/.config/pi-web
WEB_DATA_DIR="$DATA_DIR/pi-web/data"         # -> /home/coder/.pi-web
AGENT_DIR_HOST="$HOME/.pi/agent"

# ============================================
# COLOR DEFINITIONS (with defaults if not set)
# ============================================

: "${RED:='\033[0;31m'}"
: "${GREEN:='\033[0;32m'}"
: "${YELLOW:='\033[1;33m'}"
: "${BLUE:='\033[0;34m'}"
: "${NC:='\033[0m'}"

# ============================================
# LOGGING FUNCTIONS (use caller's style if available)
# ============================================

config_info() {
    if type print_info >/dev/null 2>&1; then
        print_info "$1"
    else
        echo -e "${BLUE}ℹ${NC} $1"
    fi
}

config_success() {
    if type print_success >/dev/null 2>&1; then
        print_success "$1"
    else
        echo -e "${GREEN}✓${NC} $1"
    fi
}

config_warning() {
    if type print_warning >/dev/null 2>&1; then
        print_warning "$1"
    else
        echo -e "${YELLOW}⚠${NC} $1"
    fi
}

config_error() {
    if type print_error >/dev/null 2>&1; then
        print_error "$1"
    else
        echo -e "${RED}✗${NC} $1"
    fi
}

# ============================================
# PI PACKAGE CATALOG
# ============================================

# Pi packages offered by setup.sh: "key|source|description".
# Third-party code that runs inside the container with access to the mounted project
# and to every credential passed in, so treat additions like any other dependency and
# pin a version (npm:name@1.2.3) when you want reproducible installs.
# The graphify-pi package is not listed: it follows setting.graphify_support.
PI_PACKAGE_CATALOG=(
    "matt_pocock_skills|npm:pi-matt-pocock-skills|Matt Pocock's engineering skills (grilling, TDD, code review, spec/tickets) with a subagent tool, 5 agents (scout, planner, implementer, 2 reviewers) and 3 workflow prompts"
    "subagents|npm:pi-subagents|Single-agent delegation and scripted multi-agent workflows (may overlap with the subagent tool of matt_pocock_skills)"
    "web_access|npm:pi-web-access|Web search, URL fetching, GitHub repo cloning, PDF extraction"
    "lens|npm:pi-lens|Real-time code feedback: LSP, linters, formatters, type checking"
    "ask_user|npm:@juicesharp/rpiv-ask-user-question|Structured questionnaires the model can put to you instead of guessing"
    "todo|npm:@juicesharp/rpiv-todo|Todo list for the model, shown as a live overlay"
    "background_tasks|npm:pi-background-tasks|Durable background shell tasks and read-only delegated agents"
)

# Package sources must be npm: or git: specs without whitespace or shell metacharacters
# (they are handed to 'pi install' inside the container).
valid_pi_source() {
    [[ "$1" =~ ^(npm|git):[A-Za-z0-9@/._:+~-]+$ ]]
}

# ============================================
# CONFIG STATE (global arrays, populated by parse_config)
# ============================================

declare -a CUSTOM_MOUNTS=()      # Array of "host_path:container_path[:rw]"
declare -a CUSTOM_ENV_VARS=()    # Array of "VARIABLE_NAME"
declare -a PI_PACKAGES=()        # Array of "key=source" ("custom<N>" as key for user-supplied sources)
declare -a DOCKER_MOUNT_ARGS=()  # Array of docker -v arguments (populated by build_mount_args)
declare -a DOCKER_ENV_ARGS=()    # Array of docker -e arguments (populated by build_env_args)
declare -a VOLUME_ARGS=()        # Array of standard volume mount arguments (populated by build_standard_volume_args)
declare -a GIT_WORKTREE_ARGS=()  # Array of docker args for git worktree support (populated by build_git_worktree_args)
SSH_AGENT_SUPPORT=false          # Boolean flag for SSH agent forwarding support
GRAPHIFY_SUPPORT=true            # Boolean flag for the per-project graphify knowledge graph (opt-out)
PLANTUML_SUPPORT=true            # Boolean flag for the in-container PlantUML server (opt-out)
HOST_PI_CONFIG=false             # Boolean flag: mount the host's ~/.pi/agent instead of the private agent dir
WEB_HOST=127.0.0.1               # Address pi-web binds to inside the container (host network)
WEB_PORT=8504                    # Port pi-web listens on

# ============================================
# SHARED HELPERS
# ============================================

# Compute the container mount path for a project directory.
# Strips $HOME prefix so the path is portable across machines/users.
# Example: /home/user/projects/acme/frontend -> /projects/acme/frontend
#          /opt/work/myproject                -> /opt/work/myproject (unchanged)
# Usage: container_path=$(compute_container_path "/home/user/projects/myapp")
compute_container_path() {
    local host_path="$1"

    if [[ "$host_path" == "$HOME"/* ]]; then
        echo "${host_path#"$HOME"}"
    else
        echo "$host_path"
    fi
}

# Host directory that backs /home/coder/.pi/agent for the current configuration
agent_dir() {
    if [ "$HOST_PI_CONFIG" = true ]; then
        echo "$AGENT_DIR_HOST"
    else
        echo "$AGENT_DIR_PRIVATE"
    fi
}

# Ensure all required host directories exist (so Docker does not create them as root)
ensure_pi_dirs() {
    mkdir -p "$(agent_dir)" 2>/dev/null || true
    mkdir -p "$WEB_CONFIG_DIR" 2>/dev/null || true
    mkdir -p "$WEB_DATA_DIR" 2>/dev/null || true
    # Credentials live in the agent directory. Only tighten the private one: the
    # host's own ~/.pi/agent (setting.host_pi_config) is left as the user set it.
    chmod 700 "$AGENT_DIR_PRIVATE" 2>/dev/null || true
}

# Check if Docker image exists locally
# Usage: check_image "$IMAGE_NAME"
check_image() {
    local image_name="$1"
    if ! docker image inspect "$image_name" >/dev/null 2>&1; then
        config_error "Docker image '$image_name' not found. Run '$0 build' first."
        return 1
    fi
}

# Sanitize a string for use as part of a Docker container name
# Docker container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]
# Usage: sanitize_container_name "my project dir"
sanitize_container_name() {
    local name="$1"
    name=$(echo "$name" | tr -cd '[:alnum:]._-')
    # Ensure it starts with alphanumeric
    while [[ "$name" =~ ^[^[:alnum:]] ]]; do name="${name#?}"; done
    [ -z "$name" ] && name="project"
    echo "$name"
}

# Generate a random hex suffix for container names
generate_random_suffix() {
    printf '%04x%04x' $RANDOM $RANDOM
}

# Detect if a directory is a git worktree and return the main repo's .git directory path
# A worktree has a .git FILE (not directory) containing "gitdir: <path>"
# Returns (via stdout): "<git_common_dir>" if worktree, empty string otherwise
# Usage: main_git_dir=$(detect_git_worktree "/path/to/worktree")
detect_git_worktree() {
    local project_dir="$1"

    # Quick check: if .git is a directory (normal repo) or doesn't exist, not a worktree
    if [ ! -f "$project_dir/.git" ]; then
        return 0
    fi

    # Use git to reliably resolve paths (handles relative/absolute gitdir pointers)
    if ! command -v git >/dev/null 2>&1; then
        config_warning "Git worktree detected but 'git' is not installed on the host — git info will be unavailable in container"
        return 0
    fi

    # git rev-parse --git-common-dir gives us the shared .git directory
    local git_common_dir
    git_common_dir=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null) || return 0

    # Resolve to absolute path
    if [[ "$git_common_dir" != /* ]]; then
        git_common_dir=$(cd "$project_dir" && cd "$git_common_dir" && pwd)
    else
        git_common_dir=$(cd "$git_common_dir" && pwd)
    fi

    # Sanity check: the common dir should be a real .git directory
    if [ ! -d "$git_common_dir/objects" ] || [ ! -d "$git_common_dir/refs" ]; then
        return 0
    fi

    echo "$git_common_dir"
}

# Build Docker volume/bind args needed for git worktree support
# When the project is a git worktree, the .git file points to the main repo's
# .git directory which lives outside the project dir. We mount the main .git
# directory (read-only) at its real host path so the gitdir pointer resolves
# correctly inside the container.
#
# Read-only is intentional: it preserves the sandbox boundary (container only
# has write access to the mounted project directory). Read operations like
# git log, status, diff, and branch work. Write operations (commit, stash,
# fetch) will fail — run those on the host.
#
# Populates GIT_WORKTREE_ARGS array
# Usage: build_git_worktree_args "/path/to/project"
build_git_worktree_args() {
    local project_dir="$1"

    GIT_WORKTREE_ARGS=()

    local git_common_dir
    git_common_dir=$(detect_git_worktree "$project_dir")

    if [ -z "$git_common_dir" ]; then
        return 0
    fi

    config_info "Git worktree detected — mounting main .git directory (read-only) for git support"
    config_info "Main git directory: $git_common_dir"

    # Mount the main repo's .git directory at its real host path (read-only)
    GIT_WORKTREE_ARGS+=(-v "$git_common_dir:$git_common_dir:ro")
}

# Sources of all Pi packages to install on launch, space-separated, de-duplicated.
# Includes graphify-pi while Graphify support is on.
# Usage: sources=$(collect_pi_package_sources)
collect_pi_package_sources() {
    local -a sources=()
    local entry source existing seen

    [ "$GRAPHIFY_SUPPORT" = true ] && sources+=("npm:graphify-pi")

    for entry in "${PI_PACKAGES[@]}"; do
        source="${entry#*=}"
        if ! valid_pi_source "$source"; then
            config_warning "Ignoring invalid Pi package source in config: $source"
            continue
        fi
        seen=false
        for existing in "${sources[@]}"; do
            [ "$existing" = "$source" ] && seen=true
        done
        [ "$seen" = true ] || sources+=("$source")
    done

    echo "${sources[*]}"
}

# Build common Docker run arguments shared by every container the wrapper starts
# Populates DOCKER_COMMON_ARGS array
# Usage: build_common_docker_args [project_setup]
#   project_setup=true lets the entrypoint build/refresh the project's graphify graph
# A caller can set PI_SYNC_PACKAGES=false (as a local) to start the container without
# the entrypoint installing the configured Pi packages, e.g. for 'pkg remove'.
build_common_docker_args() {
    local project_setup="${1:-false}"
    local packages=""
    [ "${PI_SYNC_PACKAGES:-true}" = true ] && packages=$(collect_pi_package_sources)

    # shellcheck disable=SC2034  # DOCKER_COMMON_ARGS is used by callers that source this file
    DOCKER_COMMON_ARGS=(
        --rm
        --network host
        -e "HOST_UID=$(id -u)"
        -e "HOST_GID=$(id -g)"
        -e "TERM=${TERM:-xterm-256color}"
        -e "GRAPHIFY_SUPPORT=$GRAPHIFY_SUPPORT"
        -e "PLANTUML_SUPPORT=$PLANTUML_SUPPORT"
        -e "PI_PROJECT_SETUP=$project_setup"
        -e "PI_PACKAGES=$packages"
        -e "PI_WEB_HOST=$WEB_HOST"
        -e "PI_WEB_PORT=$WEB_PORT"
    )

    # Pass terminal identification variables so applications inside the container
    # can detect the host terminal and use its capabilities correctly.
    # Required for kitty OSC 99 terminal-mediated desktop notifications, true-color
    # rendering, and other terminal-specific features. All are conditional so they
    # have no effect on non-kitty terminals.
    local term_var
    for term_var in TERM_PROGRAM TERM_PROGRAM_VERSION KITTY_WINDOW_ID COLORTERM; do
        if [ -n "${!term_var}" ]; then
            DOCKER_COMMON_ARGS+=(-e "$term_var=${!term_var}")
        fi
    done
}

# Build standard volume mount arguments
# Populates VOLUME_ARGS and CONTAINER_WORKDIR
# The project is mounted at a path derived from the host path (with $HOME stripped)
# so that Pi stores a unique, meaningful session directory per project.
# Usage: build_standard_volume_args "/path/to/project" [include_docker_socket]
build_standard_volume_args() {
    local project_dir="$1"
    local include_docker_socket="${2:-false}"

    VOLUME_ARGS=()

    # Compute container-side mount path: strip $HOME prefix for portability
    # e.g. /home/user/projects/acme/frontend -> /projects/acme/frontend
    CONTAINER_WORKDIR=$(compute_container_path "$project_dir")

    # Project directory (read-write) — mounted at the computed path
    # Skipped when no project is given (e.g. auth) or when it resolves to $HOME itself
    if [ -n "$project_dir" ] && [ -n "$CONTAINER_WORKDIR" ]; then
        VOLUME_ARGS+=(-v "$project_dir:$CONTAINER_WORKDIR")
        build_git_worktree_args "$project_dir"
    fi

    # Pi agent directory (read-write): auth.json, settings.json, sessions, trust.json,
    # installed packages. Pi writes all of it, so it cannot be mounted read-only; the
    # private default keeps it separate from the host's own Pi setup.
    VOLUME_ARGS+=(-v "$(agent_dir):/home/coder/.pi/agent")

    # pi-web state: its config (host/port, registered projects) and runtime data
    VOLUME_ARGS+=(-v "$WEB_CONFIG_DIR:/home/coder/.config/pi-web")
    VOLUME_ARGS+=(-v "$WEB_DATA_DIR:/home/coder/.pi-web")

    # Gradle home (optional) — shares the dependency and wrapper cache with the host
    # gradle.properties is re-mounted read-only on top so credentials cannot be rewritten
    if [ -d "$HOME/.gradle" ]; then
        VOLUME_ARGS+=(-v "$HOME/.gradle:/home/coder/.gradle")
    fi
    if [ -f "$HOME/.gradle/gradle.properties" ]; then
        VOLUME_ARGS+=(-v "$HOME/.gradle/gradle.properties:/home/coder/.gradle/gradle.properties:ro")
    fi

    # Maven repository (optional) — avoids re-downloading artifacts on every run
    if [ -d "$HOME/.m2" ]; then
        VOLUME_ARGS+=(-v "$HOME/.m2:/home/coder/.m2")
    fi

    # npm cache (optional) — speeds up Pi package installs and npx-based tooling
    if [ -d "$HOME/.npm" ]; then
        VOLUME_ARGS+=(-v "$HOME/.npm:/home/coder/.npm")
    fi

    # Git configuration (optional) — ensures commits use the host user's name and email
    if command -v git >/dev/null 2>&1 && [ -f "$HOME/.gitconfig" ]; then
        VOLUME_ARGS+=(-v "$HOME/.gitconfig:/home/coder/.gitconfig:ro")
    fi

    # NPM configuration (optional)
    if [ -f "$HOME/.npmrc" ]; then
        VOLUME_ARGS+=(-v "$HOME/.npmrc:/home/coder/.npmrc:ro")
    fi

    # Agent-compatible skills directory (optional, read-only)
    # Pi reads user skills from ~/.agents/skills/<name>/SKILL.md
    if [ -d "$HOME/.agents" ]; then
        VOLUME_ARGS+=(-v "$HOME/.agents:/home/coder/.agents:ro")
    fi

    # Docker socket (optional, for Docker-in-Docker operations)
    if [ "$include_docker_socket" = true ] && [ -S /var/run/docker.sock ]; then
        VOLUME_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
    fi
}

# ============================================
# CONFIG FILE OPERATIONS
# ============================================

# Check if config file exists
config_exists() {
    [ -f "$CONFIG_FILE" ]
}

# Initialize config file with header
init_config_file() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# Pi Web Dockerized User Configuration
# Generated by setup.sh - edit manually or re-run setup.sh to modify

# Settings
# SSH Agent Forwarding (enables git over SSH in container)
# Automatically mounts SSH_AUTH_SOCK socket and passes the environment variable
# setting.ssh_agent_support=false

# Graphify (per-project code knowledge graph)
# Enabled by default. Installs the graphify-pi package and, for 'run' and 'exec',
# builds the graph in <project>/graphify-out on launch, then refreshes it
# incrementally. Set to false to skip all of that (faster startup, no graphify-out).
# See: https://pypi.org/project/graphifyy/
# setting.graphify_support=true

# PlantUML server (pumlsrv) started inside the container for 'pumlcli'
# setting.plantuml_support=true

# Share the host's ~/.pi/agent (credentials, extensions, sessions) with the container
# instead of the private directory ~/.local/share/pi-web-dockerized/agent.
# Pi's containerization guide advises against this: whatever runs in the container
# can then read your host credentials and modify your host extensions.
# setting.host_pi_config=false

# pi-web (browser UI, './pi-web-dockerized.sh web'). The container uses the host
# network, so 127.0.0.1 means: reachable from this machine only.
# setting.web_host=127.0.0.1
# setting.web_port=8504

# Pi packages (extensions, skills, agents, prompts) installed on first launch
# Format: package.<name>=<npm:name[@version] | git:host/path[@ref]>
# Examples:
#   package.matt_pocock_skills=npm:pi-matt-pocock-skills
#   package.web_access=npm:pi-web-access

# Custom volume mounts (read-only by default)
# Format: mount.<name>=<host_path>:<container_path>[:rw]
# Examples:
#   mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
#   mount.ssh=~/.ssh:/home/coder/.ssh:rw
#   mount.gitignore_global=~/.config/git/gitignore_global:/home/coder/.config/git/gitignore_global

# Environment variables to pass from host to container
# Format: env.<name>=<variable_name>
# Examples:
#   env.anthropic=ANTHROPIC_API_KEY
#   env.openai=OPENAI_API_KEY
#   env.aws_bedrock=AWS_BEARER_TOKEN_BEDROCK
EOF
    config_success "Created config file at $CONFIG_FILE"
}

# Trim leading/trailing whitespace of $1 and print it
trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Load config file into arrays
load_config() {
    if ! config_exists; then
        config_warning "Config file not found at $CONFIG_FILE"
        return 1
    fi

    CUSTOM_MOUNTS=()
    CUSTOM_ENV_VARS=()
    PI_PACKAGES=()

    SSH_AGENT_SUPPORT=false
    GRAPHIFY_SUPPORT=true
    PLANTUML_SUPPORT=true
    HOST_PI_CONFIG=false
    WEB_HOST=127.0.0.1
    WEB_PORT=8504

    local key value name
    while IFS='=' read -r key value; do
        key=$(trim "$key")
        value=$(trim "$value")
        [[ "$key" =~ ^# ]] && continue
        [ -n "$value" ] || continue

        case "$key" in
            mount.*)
                CUSTOM_MOUNTS+=("$value")
                ;;
            env.*)
                CUSTOM_ENV_VARS+=("$value")
                ;;
            package.*)
                name="${key#package.}"
                PI_PACKAGES+=("$name=$value")
                ;;
            setting.ssh_agent_support)
                [ "$value" = true ] && SSH_AGENT_SUPPORT=true
                ;;
            setting.graphify_support)
                # Opt-out setting: enabled unless explicitly disabled with =false
                [ "$value" = false ] && GRAPHIFY_SUPPORT=false
                ;;
            setting.plantuml_support)
                [ "$value" = false ] && PLANTUML_SUPPORT=false
                ;;
            setting.host_pi_config)
                [ "$value" = true ] && HOST_PI_CONFIG=true
                ;;
            setting.web_host)
                # Plain host or IP; the value ends up in an environment variable
                [[ "$value" =~ ^[A-Za-z0-9.:-]+$ ]] && WEB_HOST="$value"
                ;;
            setting.web_port)
                [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] && WEB_PORT="$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    return 0
}

# Save current arrays to config file
save_config() {
    mkdir -p "$CONFIG_DIR"

    {
        echo "# Pi Web Dockerized User Configuration"
        echo "# Generated by setup.sh - edit manually or re-run setup.sh to modify"
        echo ""
        echo "# Settings"
        echo "# SSH Agent Forwarding (enables git over SSH in container)"
        echo "# Automatically mounts SSH_AUTH_SOCK socket and passes the environment variable"
        echo "setting.ssh_agent_support=$SSH_AGENT_SUPPORT"
        echo ""
        echo "# Graphify (per-project code knowledge graph, installs the graphify-pi package)"
        echo "# Enabled by default; set to false to skip package install and graph builds."
        echo "# See: https://pypi.org/project/graphifyy/"
        echo "setting.graphify_support=$GRAPHIFY_SUPPORT"
        echo ""
        echo "# PlantUML server (pumlsrv) started inside the container for 'pumlcli'"
        echo "setting.plantuml_support=$PLANTUML_SUPPORT"
        echo ""
        echo "# Share the host's ~/.pi/agent with the container (not recommended, see README)"
        echo "setting.host_pi_config=$HOST_PI_CONFIG"
        echo ""
        echo "# pi-web (browser UI, './pi-web-dockerized.sh web')"
        echo "setting.web_host=$WEB_HOST"
        echo "setting.web_port=$WEB_PORT"
        echo ""
        echo "# Pi packages (extensions, skills, agents, prompts) installed on first launch"
        echo "# Format: package.<name>=<npm:name[@version] | git:host/path[@ref]>"

        local entry
        for entry in "${PI_PACKAGES[@]}"; do
            echo "package.$entry"
        done

        echo ""
        echo "# Custom volume mounts (read-only by default)"
        echo "# Format: mount.<name>=<host_path>:<container_path>[:rw]"

        local i
        for i in "${!CUSTOM_MOUNTS[@]}"; do
            echo "mount.custom$(( i + 1 ))=${CUSTOM_MOUNTS[$i]}"
        done

        echo ""
        echo "# Environment variables to pass from host to container"
        echo "# Format: env.<name>=<variable_name>"

        for i in "${!CUSTOM_ENV_VARS[@]}"; do
            echo "env.custom$(( i + 1 ))=${CUSTOM_ENV_VARS[$i]}"
        done
    } > "$CONFIG_FILE"

    config_success "Saved configuration to $CONFIG_FILE"
}

# ============================================
# CONFIG PARSING (used at runtime by all scripts)
# ============================================

# Parse config file into global arrays
parse_config() {
    load_config || return 0  # Continue even if load fails
}

# Build docker volume mount arguments from CUSTOM_MOUNTS array
# Populates DOCKER_MOUNT_ARGS array with -v arguments
build_mount_args() {
    DOCKER_MOUNT_ARGS=()

    local mount host_path rest container_path mode
    for mount in "${CUSTOM_MOUNTS[@]}"; do
        # Expand all occurrences of ~ to home directory
        mount="${mount//\~/$HOME}"

        # Extract host_path, container_path, and mode
        host_path="${mount%%:*}"
        rest="${mount#*:}"
        container_path="${rest%:*}"
        mode="${rest##*:}"

        if [ "$mode" = "$container_path" ]; then
            # No mode specified, default to read-only
            DOCKER_MOUNT_ARGS+=(-v "$host_path:$container_path:ro")
        else
            # Mode was specified (rw, ro, ...), use it as-is
            DOCKER_MOUNT_ARGS+=(-v "$host_path:$container_path:$mode")
        fi
    done

    # Handle SSH agent forwarding if enabled
    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "${SSH_AUTH_SOCK:-}" ]; then
            if [ -S "$SSH_AUTH_SOCK" ]; then
                DOCKER_MOUNT_ARGS+=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK")
            else
                config_warning "SSH agent support enabled but socket not found at $SSH_AUTH_SOCK"
            fi
        else
            config_warning "SSH agent support enabled but SSH_AUTH_SOCK is not set"
        fi
    fi
}

# Build docker environment variable arguments from CUSTOM_ENV_VARS array
# Populates DOCKER_ENV_ARGS array with -e arguments
build_env_args() {
    DOCKER_ENV_ARGS=()

    local var_name var_value
    for var_name in "${CUSTOM_ENV_VARS[@]}"; do
        # Validate variable name matches expected pattern
        if ! [[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            config_warning "Invalid variable name in config: $var_name (must be uppercase with underscores, skipping)"
            continue
        fi

        # Only add if the variable is set in the (exported) host environment. Passing
        # just the name makes Docker read the value itself, so secrets never show up
        # in 'ps' output or in DRY_RUN output.
        var_value=$(printenv "$var_name" || true)

        if [ -n "$var_value" ]; then
            DOCKER_ENV_ARGS+=(-e "$var_name")
        else
            config_warning "Environment variable '$var_name' not set in host environment (skipping)"
        fi
    done

    # Handle SSH agent forwarding if enabled
    if [ "$SSH_AGENT_SUPPORT" = true ] && [ -n "${SSH_AUTH_SOCK:-}" ]; then
        DOCKER_ENV_ARGS+=(-e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
    fi
}

# ============================================
# CONFIG MANAGEMENT (used by setup.sh)
# ============================================

# Add a mount entry to arrays
# add_mount <host_path> <container_path> [rw]
add_mount() {
    local host_path="$1"
    local container_path="$2"
    local mode="${3:-}"

    if [ -z "$host_path" ] || [ -z "$container_path" ]; then
        config_error "add_mount requires host_path and container_path"
        return 1
    fi

    # Validate host path exists
    local expanded_path="${host_path/\~/$HOME}"
    if [ ! -e "$expanded_path" ]; then
        config_warning "Host path does not exist: $expanded_path"
    fi

    if [ -n "$mode" ] && [ "$mode" != "ro" ] && [ "$mode" != "rw" ]; then
        config_error "Invalid mode: $mode (must be 'ro' or 'rw')"
        return 1
    fi

    local mount_entry="$host_path:$container_path"
    [ -n "$mode" ] && mount_entry="$mount_entry:$mode"

    CUSTOM_MOUNTS+=("$mount_entry")
}

# Add an environment variable entry to arrays
# add_env_var <VARIABLE_NAME>
add_env_var() {
    local var_name="$1"

    if [ -z "$var_name" ]; then
        config_error "add_env_var requires variable name"
        return 1
    fi

    CUSTOM_ENV_VARS+=("$var_name")
}

# Is the Pi package with this catalog key currently selected?
# Usage: pi_package_selected <key>
pi_package_selected() {
    local entry
    for entry in "${PI_PACKAGES[@]}"; do
        [ "${entry%%=*}" = "$1" ] && return 0
    done
    return 1
}

# Remove the Pi package entry with this key
# Usage: remove_pi_package <key>
remove_pi_package() {
    local -a kept=()
    local entry
    for entry in "${PI_PACKAGES[@]}"; do
        [ "${entry%%=*}" = "$1" ] || kept+=("$entry")
    done
    PI_PACKAGES=("${kept[@]}")
}

# ============================================
# INTERACTIVE PROMPTS (used by setup.sh)
# ============================================

# Suggest a container path based on host path
# suggest_container_path <host_path> [default]
suggest_container_path() {
    local host_path="$1"
    local default="${2:-/home/coder/$(basename "$host_path")}"

    # For common paths, suggest sensible defaults
    if [[ "$host_path" == *"/.gitconfig" ]]; then
        echo "/home/coder/.gitconfig"
    elif [[ "$host_path" == *"/.ssh" ]]; then
        echo "/home/coder/.ssh"
    elif [[ "$host_path" == *"/.config/git"* ]]; then
        echo "/home/coder/.config/git/$(basename "$host_path")"
    elif [[ "$host_path" == *"/.gradle"* ]]; then
        echo "/home/coder/.gradle/$(basename "$host_path")"
    else
        echo "$default"
    fi
}

# Ask a yes/no question
# Usage: ask_yes_no "<prompt>" <default: y|n>   (returns 0 for yes)
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local hint="y/N"
    [ "$default" = y ] && hint="Y/n"

    local answer
    read -r -p "$prompt ($hint): " answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

# Ask user how to handle existing config
# Sets global: CONFIG_MODE ("new", "append", "overwrite", or "skip")
prompt_config_mode() {
    if ! config_exists; then
        CONFIG_MODE="new"
        return 0
    fi

    echo ""
    config_info "Configuration file already exists at $CONFIG_FILE"

    PS3="Choose an option: "
    local mode
    select mode in "Append (add new entries)" "Overwrite (replace config)" "Skip (keep existing)"; do
        case "$mode" in
            "Append (add new entries)")
                CONFIG_MODE="append"
                config_success "Will append new entries to existing config"
                break
                ;;
            "Overwrite (replace config)")
                CONFIG_MODE="overwrite"
                config_warning "Will replace existing config"
                break
                ;;
            "Skip (keep existing)")
                CONFIG_MODE="skip"
                config_info "Skipping config setup"
                break
                ;;
            *)
                config_error "Invalid option"
                ;;
        esac
    done
}

# Interactive mount addition
# Prompts user repeatedly until they enter a blank line
prompt_custom_mounts() {
    echo ""
    config_info "Configure custom volume mounts (optional)"
    echo "Enter host paths to mount in the container (read-only by default)"
    echo "Press Enter with empty input to finish"
    echo ""

    local host_path expanded_path proceed suggested container_path rw_mode mode
    while true; do
        read -r -p "Host path: " host_path

        # Allow blank to exit
        if [ -z "$host_path" ]; then
            break
        fi

        # Expand ~ for validation
        expanded_path="${host_path/\~/$HOME}"

        if [ ! -e "$expanded_path" ]; then
            config_warning "Path does not exist: $expanded_path"
            read -r -p "Continue anyway? (y/N): " proceed
            [[ "$proceed" =~ ^[Yy]$ ]] || continue
        fi

        # Suggest container path
        suggested=$(suggest_container_path "$host_path")
        read -r -p "Container path [$suggested]: " container_path
        container_path="${container_path:-$suggested}"

        # Ask about read-write
        read -r -p "Read-write? (y/N): " rw_mode
        mode=""
        if [[ "$rw_mode" =~ ^[Yy]$ ]]; then
            mode="rw"
        fi

        # Add the mount
        add_mount "$host_path" "$container_path" "$mode"
        config_success "Added mount: $host_path -> $container_path${mode:+ ($mode)}"
        echo ""
    done
}

# Interactive environment variable addition
# Prompts user repeatedly until they enter a blank line
prompt_env_vars() {
    echo ""
    config_info "Configure environment variables (optional)"
    echo "Specify host environment variables to pass to the container."
    echo "Provider API keys go here if you do not want to run /login inside Pi."
    echo "Press Enter with empty input to finish"
    echo ""

    echo "Common examples:"
    echo "  ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY"
    echo "  AWS_BEARER_TOKEN_BEDROCK - AWS Bedrock API key"
    echo ""

    local var_name proceed
    while true; do
        read -r -p "Environment variable name: " var_name

        # Allow blank to exit
        if [ -z "$var_name" ]; then
            break
        fi

        # Validate variable name (basic check)
        if ! [[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            config_error "Invalid variable name: $var_name (must be uppercase with underscores)"
            continue
        fi

        # Check if variable is set in environment
        if [ -z "${!var_name:-}" ]; then
            config_warning "Variable '$var_name' is not set in current environment"
            read -r -p "Add anyway? (y/N): " proceed
            [[ "$proceed" =~ ^[Yy]$ ]] || continue
        fi

        # Add the variable
        add_env_var "$var_name"
        config_success "Added environment variable: $var_name"
        echo ""
    done
}

# Interactive SSH agent support prompt
prompt_ssh_agent_support() {
    echo ""
    config_info "SSH Agent Forwarding Support"
    echo "Enable this if you use SSH agent forwarding for git operations over SSH."
    echo "This automatically mounts the SSH socket and passes the SSH_AUTH_SOCK variable."
    echo ""

    local default=n
    [ "$SSH_AGENT_SUPPORT" = true ] && default=y
    if ask_yes_no "Enable SSH agent forwarding support?" "$default"; then
        SSH_AGENT_SUPPORT=true
        config_success "SSH agent forwarding support enabled"
    else
        SSH_AGENT_SUPPORT=false
        config_info "SSH agent forwarding support disabled"
    fi
}

# Interactive Graphify prompt
# GRAPHIFY_SUPPORT defaults to true, so the question is phrased as an opt-out
prompt_graphify_support() {
    echo ""
    config_info "Graphify Knowledge Graph (https://pypi.org/project/graphifyy/)"
    echo "Graphify builds a per-project code knowledge graph (graphify-out/) from the"
    echo "local AST — no API key needed. The graphify-pi Pi package makes Pi consult it"
    echo "before grepping raw files and adds a /graphify command. For 'run' and 'exec'"
    echo "the graph is built on first launch and refreshed incrementally on every run."
    echo ""

    local default=y
    [ "$GRAPHIFY_SUPPORT" = true ] || default=n
    if ask_yes_no "Enable Graphify support?" "$default"; then
        GRAPHIFY_SUPPORT=true
        config_success "Graphify support enabled"
    else
        GRAPHIFY_SUPPORT=false
        config_info "Graphify disabled"
    fi
}

# Interactive PlantUML prompt
prompt_plantuml_support() {
    echo ""
    config_info "PlantUML Server (https://github.com/michael72/pumlsrv)"
    echo "Starts the pumlsrv server in the container so 'pumlcli' can render diagrams."
    echo ""

    local default=y
    [ "$PLANTUML_SUPPORT" = true ] || default=n
    if ask_yes_no "Start the PlantUML server in the container?" "$default"; then
        PLANTUML_SUPPORT=true
        config_success "PlantUML server enabled"
    else
        PLANTUML_SUPPORT=false
        config_info "PlantUML server disabled"
    fi
}

# Interactive prompt: which Pi agent directory does the container use?
prompt_host_pi_config() {
    echo ""
    config_info "Pi Agent Directory"
    echo "By default the container uses its own agent directory:"
    echo "  $AGENT_DIR_PRIVATE"
    echo "Sign in once with './pi-web-dockerized.sh auth' (or pass API keys as environment"
    echo "variables below). Sharing your host's ~/.pi/agent instead gives the container"
    echo "your credentials, extensions and sessions — and write access to all of them."
    echo ""

    local default=n
    [ "$HOST_PI_CONFIG" = true ] && default=y
    if ask_yes_no "Share the host's ~/.pi/agent with the container?" "$default"; then
        HOST_PI_CONFIG=true
        config_warning "Container will use $AGENT_DIR_HOST"
    else
        HOST_PI_CONFIG=false
        config_info "Container will use its private agent directory"
    fi
}

# Interactive pi-web prompt
prompt_web_settings() {
    echo ""
    config_info "pi-web Browser UI (https://github.com/jmfederico/pi-web)"
    echo "'./pi-web-dockerized.sh web' serves a browser UI for Pi sessions."
    echo "The container uses the host network, so 127.0.0.1 is reachable from this"
    echo "machine only. pi-web has no authentication: bind another address only on a"
    echo "network you trust (or put an authenticated reverse proxy in front of it)."
    echo ""

    local answer
    read -r -p "Port [$WEB_PORT]: " answer
    if [ -n "$answer" ]; then
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le 65535 ]; then
            WEB_PORT="$answer"
        else
            config_warning "Invalid port '$answer' — keeping $WEB_PORT"
        fi
    fi

    read -r -p "Bind address [$WEB_HOST]: " answer
    if [ -n "$answer" ]; then
        if [[ "$answer" =~ ^[A-Za-z0-9.:-]+$ ]]; then
            WEB_HOST="$answer"
        else
            config_warning "Invalid address '$answer' — keeping $WEB_HOST"
        fi
    fi
}

# Interactive Pi package selection: catalog first, then free-form sources
prompt_pi_packages() {
    echo ""
    config_info "Pi Packages — skills, agents, extensions"
    echo "Installed into the container's Pi agent directory on first launch. Pi packages"
    echo "run with the container's permissions: review third-party code before enabling it."
    echo ""

    local entry key source description answer default
    for entry in "${PI_PACKAGE_CATALOG[@]}"; do
        IFS='|' read -r key source description <<< "$entry"
        echo "  $source"
        echo "    $description"

        default=n
        pi_package_selected "$key" && default=y
        [ "$key" = matt_pocock_skills ] && ! config_exists && default=y

        if ask_yes_no "  Install $source?" "$default"; then
            pi_package_selected "$key" || PI_PACKAGES+=("$key=$source")
        else
            remove_pi_package "$key"
        fi
        echo ""
    done

    echo "Further packages: npm:<name>[@version] or git:<host>/<path>[@ref]."
    echo "Browse https://pi.dev/packages. Press Enter with empty input to finish."
    local n
    while true; do
        read -r -p "Package source: " answer
        [ -n "$answer" ] || break
        if ! valid_pi_source "$answer"; then
            config_error "Invalid source: $answer (expected npm:<name> or git:<repo>, no spaces)"
            continue
        fi
        n=1
        while pi_package_selected "custom$n"; do n=$((n + 1)); done
        PI_PACKAGES+=("custom$n=$answer")
        config_success "Added package: $answer"
    done
}

# Print current configuration (for debugging/info)
print_config() {
    echo ""
    echo "Current configuration:"
    echo "  Config file: $CONFIG_FILE"
    echo "  SSH agent forwarding: $SSH_AGENT_SUPPORT"
    echo "  Graphify support: $GRAPHIFY_SUPPORT"
    echo "  PlantUML server: $PLANTUML_SUPPORT"
    echo "  Pi agent directory: $(agent_dir)$([ "$HOST_PI_CONFIG" = true ] && echo ' (host)')"
    echo "  pi-web: http://$WEB_HOST:$WEB_PORT"

    echo ""
    local sources
    sources=$(collect_pi_package_sources)
    if [ -n "$sources" ]; then
        echo "  Pi packages:"
        local source
        for source in $sources; do
            echo "    $source"
        done
    else
        echo "  Pi packages: (none)"
    fi

    local i
    echo ""
    if [ ${#CUSTOM_MOUNTS[@]} -gt 0 ]; then
        echo "  Custom mounts:"
        for i in "${!CUSTOM_MOUNTS[@]}"; do
            echo "    [$i] ${CUSTOM_MOUNTS[$i]}"
        done
    else
        echo "  Custom mounts: (none)"
    fi

    echo ""
    if [ ${#CUSTOM_ENV_VARS[@]} -gt 0 ]; then
        echo "  Environment variables:"
        for i in "${!CUSTOM_ENV_VARS[@]}"; do
            echo "    [$i] ${CUSTOM_ENV_VARS[$i]}"
        done
    else
        echo "  Environment variables: (none)"
    fi
    echo ""
}

# ============================================
# SETUP ORCHESTRATION (used by setup.sh)
# ============================================

# Run every prompt, then persist
run_config_prompts() {
    prompt_pi_packages
    prompt_graphify_support
    prompt_plantuml_support
    prompt_ssh_agent_support
    prompt_host_pi_config
    prompt_web_settings
    prompt_custom_mounts
    prompt_env_vars
    save_config
    print_config
}

# Main entry point for interactive configuration setup
# Handles: mode selection, prompts, config persistence
interactive_config_setup() {
    prompt_config_mode

    case "$CONFIG_MODE" in
        skip)
            echo ""
            echo "Skipping configuration."
            echo "You can run setup.sh again later to choose tools, agents and plugins."
            ;;
        append)
            load_config
            run_config_prompts
            ;;
        overwrite|new)
            # Start from the defaults, not from whatever an old config contained
            CUSTOM_MOUNTS=()
            CUSTOM_ENV_VARS=()
            PI_PACKAGES=()
            run_config_prompts
            ;;
    esac
}
