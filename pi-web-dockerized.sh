#!/bin/bash

# Pi Docker Wrapper Script
# This script makes it easy to run the Pi coding agent (and its web UI) in a secure Docker container

set -e

# Resolve symlinks so SCRIPT_DIR points to the real source directory
# This allows the script to be invoked via a symlink in PATH (e.g. ~/.local/bin)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE_NAME="pi-web-dockerized:latest"

# Colors for output (defined before sourcing config-lib so it picks them up)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Source the shared config module
source "$SCRIPT_DIR/config-lib.sh"

# Function to print colored output
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
}

# Function to build the Docker image
build_image() {
    print_info "Building Pi Docker image..."
    # Regular build uses Docker layer cache normally.
    # Only the 'update' command passes PI_BUILD_TIME to bust the layers holding Pi.
    docker build --progress=plain -t "$IMAGE_NAME" "$SCRIPT_DIR"
    print_success "Docker image built successfully"
}

# Warn when the container has no way to reach a model provider yet
check_config() {
    parse_config
    if [ ! -f "$(agent_dir)/auth.json" ] && [ ${#CUSTOM_ENV_VARS[@]} -eq 0 ]; then
        print_warning "No Pi credentials found in $(agent_dir)"
        print_info "Run '$0 auth' and use /login, or pass an API key through env.* in the config (run setup.sh)."
    fi
    ensure_pi_dirs
}

# Run a command inside the container.
# The project directory is mounted so project-level configuration applies; an empty
# one starts the container without a project (auth, models, package management).
# Usage: run_container <name_suffix> <project_dir> <docker_socket> <project_setup> <cmd...>
#   docker_socket  true to mount the host Docker socket
#   project_setup  true to let the entrypoint build the project's graphify graph
run_container() {
    local name_suffix="$1"
    local project_dir="$2"
    local docker_socket="$3"
    local project_setup="$4"
    shift 4

    if [ -n "$project_dir" ]; then
        if [ ! -d "$project_dir" ]; then
            print_error "Project directory does not exist: $project_dir"
            exit 1
        fi
        project_dir="$(cd "$project_dir" && pwd)"
    fi

    check_image "$IMAGE_NAME" || exit 1

    parse_config
    ensure_pi_dirs
    build_mount_args
    build_env_args
    build_common_docker_args "$project_setup"
    build_standard_volume_args "$project_dir" "$docker_socket"

    # Allocate a TTY only when attached to one, so the command stays pipeable
    local -a tty_args=(-i)
    [ -t 0 ] && [ -t 1 ] && tty_args=(-it)

    # CONTAINER_WORKDIR is set by build_standard_volume_args (host path with $HOME stripped)
    local -a workdir_args=()
    [ -n "$CONTAINER_WORKDIR" ] && workdir_args=(--workdir "$CONTAINER_WORKDIR" -e "PI_WORKDIR=$CONTAINER_WORKDIR")

    # A random suffix keeps concurrent runs apart; --rm removes the container on exit
    local container_name
    container_name="pi-${name_suffix}-$(generate_random_suffix)"

    local -a docker_cmd=(
        docker run "${tty_args[@]}"
        --name "$container_name"
        "${workdir_args[@]}"
        "${DOCKER_COMMON_ARGS[@]}"
        "${VOLUME_ARGS[@]}"
        "${GIT_WORKTREE_ARGS[@]}"
        "${DOCKER_MOUNT_ARGS[@]}"
        "${DOCKER_ENV_ARGS[@]}"
        "$IMAGE_NAME"
        "$@"
    )

    if [ "${DRY_RUN:-false}" = true ]; then
        print_info "Dry run — would execute:"
        echo "${docker_cmd[*]}"
        return 0
    fi

    "${docker_cmd[@]}"
}

# Function to authenticate with a model provider
# Pi has no login subcommand: OAuth and API-key login is the /login command in the TUI.
run_auth() {
    print_info "Starting Pi without a project. Type /login, choose a provider, then /quit."
    print_info "Credentials are saved in $(agent_dir)/auth.json"
    run_container auth "" false false pi
}

# Function to run Pi
run_pi() {
    local project_dir="${1:-$(pwd)}"

    # Validate project directory exists
    if [ ! -d "$project_dir" ]; then
        print_error "Project directory does not exist: $project_dir"
        exit 1
    fi

    # Convert to absolute path
    project_dir="$(cd "$project_dir" && pwd)"

    print_info "Starting Pi in Docker..."
    print_info "Project directory: $project_dir"

    if ! run_container "$(sanitize_container_name "$(basename "$project_dir")")" "$project_dir" true true pi; then
        print_error "Pi exited with an error"
        exit 1
    fi
}

# Function to run the pi-web browser UI
# DIR may be a single project or a folder of projects; either way, projects are added
# in the UI by their container path (printed below).
run_web() {
    local project_dir="${1:-$(pwd)}"

    if [ ! -d "$project_dir" ]; then
        print_error "Directory does not exist: $project_dir"
        exit 1
    fi
    project_dir="$(cd "$project_dir" && pwd)"

    parse_config
    print_info "Starting pi-web in Docker..."
    print_info "Mounted directory: $project_dir"
    print_info "Add it as a project in the UI using the path: $(compute_container_path "$project_dir")"
    print_info "Open: http://$WEB_HOST:$WEB_PORT   (Ctrl-C to stop)"
    if [ "$WEB_HOST" != 127.0.0.1 ] && [ "$WEB_HOST" != localhost ]; then
        print_warning "pi-web is bound to $WEB_HOST and has no authentication — only expose it on a trusted network"
    fi

    # Sessions live in the web daemon, so the graphify build (a run/exec feature) is skipped
    run_container web "$project_dir" true false pi-web-run
}

# Function to update Pi, pi-web and graphify
update_pi() {
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        print_info "Current versions:"
        show_version || true
    else
        print_info "Image not found, building fresh..."
    fi

    # Rebuild with cache-busting to force fresh npm installs
    print_info "Rebuilding image with the latest Pi..."
    docker build --progress=plain --build-arg "PI_BUILD_TIME=$(date +%s)" -t "$IMAGE_NAME" "$SCRIPT_DIR"

    print_info "Updated versions:"
    show_version || true
    print_success "Update complete"
    print_info "Pi packages live in $(agent_dir) — update them with '$0 pkg update'"
}

# Function to list the models available to the configured providers
list_models() {
    run_container models "" false false pi --list-models "$@"
}

# Function to manage Pi packages (list|install|remove|update|config)
# Packages are global (stored in the agent directory); the project-scoped '-l' variant
# needs a project and is therefore only available from inside Pi. A package removed here
# is installed again on the next launch while it is still listed in the config.
manage_packages() {
    local subcommand="${1:-list}"
    shift || true
    # Without this the entrypoint would first re-install what 'remove' is about to delete
    local PI_SYNC_PACKAGES=false
    run_container pkg "" false false pi "$subcommand" "$@"
}

# Function to run a non-interactive prompt and print the result
exec_prompt() {
    if [ $# -eq 0 ]; then
        print_error "A message is required: $0 exec \"<message>\" [OPTIONS]"
        exit 1
    fi
    # Docker socket is mounted because the agent executes tools here, as in 'run'
    run_container exec "$(pwd)" true true pi -p "$@"
}

# Function to open a shell in the container
run_shell() {
    run_container shell "${1:-$(pwd)}" true false bash
}

# Function to clean up Docker image
clean_image() {
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        print_info "Removing Docker image '$IMAGE_NAME'..."
        docker rmi "$IMAGE_NAME"
        print_success "Docker image removed"
    else
        print_info "Docker image '$IMAGE_NAME' does not exist"
    fi
}

# Function to show or edit configuration
show_config() {
    local subcommand="${1:-show}"

    case "$subcommand" in
        show)
            parse_config
            print_config
            ;;
        edit)
            if [ -z "${EDITOR:-}" ]; then
                print_error "EDITOR environment variable is not set"
                exit 1
            fi
            if [ ! -f "$CONFIG_FILE" ]; then
                print_warning "Config file does not exist. Running setup first..."
                "$SCRIPT_DIR/setup.sh"
            else
                "$EDITOR" "$CONFIG_FILE"
            fi
            ;;
        path)
            echo "$CONFIG_FILE"
            ;;
        *)
            print_error "Unknown config subcommand: $subcommand"
            echo "Usage: $0 config [show|edit|path]"
            exit 1
            ;;
    esac
}

# Function to show help
show_help() {
    cat << EOF
Pi Docker Wrapper

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    run [DIR]           Run Pi in Docker (default: current directory)
    web [DIR]           Run the pi-web browser UI (DIR: a project or a folder of projects)
    auth                Sign in to a model provider (starts Pi; use /login)
    models [SEARCH]     List models available to the configured providers
    exec MSG [OPTS]     Run a non-interactive prompt (pi -p)
    pkg [ARGS]          Manage Pi packages (list|install|remove|update|config, default: list)
    shell [DIR]         Open a bash shell in the container
    build               Build the Docker image
    update              Update Pi, pi-web and graphify to the latest version
    version             Show the versions in the image
    config [show|edit|path]  Show, edit, or print config file path
    clean               Remove the Docker image
    help                Show this help message

Environment Variables:
    DRY_RUN=true        Print the Docker command without executing it
    PI_DOCKERIZED_DATA_DIR   Host state directory (default: ~/.local/share/pi-web-dockerized)

Examples:
    $0 run                          # Run in current directory
    $0 run /path/to/project         # Run in specific directory
    $0 auth                         # Sign in with your LLM provider
    $0 web ~/projects               # Browser UI for everything under ~/projects
    $0 exec "Explain this repo"     # Non-interactive prompt
    $0 pkg install npm:pi-lens      # Install a Pi package
    $0 pkg list                     # Show installed Pi packages
    $0 models sonnet                # Search available models
    $0 update                       # Update to the latest version
    $0 config show                  # Show current configuration
    DRY_RUN=true $0 run             # Show Docker command without running

Getting Started:
    1. ./setup.sh                   # First-time setup: choose tools, agents and plugins
    2. $0 build                     # Build the Docker image
    3. $0 auth                      # Sign in (or pass an API key via env.* in the config)
    4. $0 run /path/to/project      # Run Pi

Security Features:
    - Isolated environment: write access only to the mounted project directory
    - Private agent directory: your host ~/.pi/agent is not shared unless you opt in
    - Non-root user: runs as the mapped host user inside the container
    - Automatic cleanup: containers are removed on exit (--rm)

Note: Docker socket is mounted for Docker-in-Docker support. This grants the
container full access to the host Docker daemon. Pi runs commands without asking
for approval, so treat the project directory as the unit of trust.

For more information, see README.md
EOF
}

# Function to show the versions baked into the image
show_version() {
    check_image "$IMAGE_NAME" || return 1
    docker run --rm --entrypoint bash "$IMAGE_NAME" -c \
        'source $NVM_DIR/nvm.sh && echo "pi $(pi --version)" && npm list -g @jmfederico/pi-web --depth=0 2>/dev/null | grep pi-web && graphify --version 2>/dev/null | sed "s/^/graphify /"'
}

# Main script logic
main() {
    check_docker

    local command="${1:-run}"
    shift || true

    case "$command" in
        run)
            check_config
            run_pi "$@"
            ;;
        web)
            check_config
            run_web "$@"
            ;;
        auth)
            parse_config
            run_auth
            ;;
        models)
            list_models "$@"
            ;;
        exec)
            check_config
            exec_prompt "$@"
            ;;
        pkg|package|packages)
            manage_packages "$@"
            ;;
        shell)
            run_shell "$@"
            ;;
        build)
            build_image
            ;;
        update)
            parse_config
            update_pi
            ;;
        version)
            show_version
            ;;
        config)
            show_config "$@"
            ;;
        clean)
            clean_image
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
