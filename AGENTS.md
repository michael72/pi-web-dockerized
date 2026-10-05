# Agent Guidelines for Pi Web Dockerized

## Project Overview

Shell script-based Docker wrapper for running the [Pi coding agent](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`) and its browser UI [pi-web](https://github.com/jmfederico/pi-web) in secure, isolated containers. Sandboxes Pi so its blast radius is limited to the mounted project directory. Counterpart of [opencode-dockerized](https://github.com/michael72/opencode-dockerized). All source is Bash shell scripts and a Dockerfile — no compiled code, no package manager files.

**Key files:**
- `pi-web-dockerized.sh` — Main wrapper (run, web, auth, models, exec, pkg, shell, build, update, version, config, clean commands)
- `config-lib.sh` — Shared library sourced by other scripts (config parsing, Pi package catalog, mount/env arg building, interactive prompts). **Not executable directly.**
- `Dockerfile` — Debian bookworm-slim + Node.js/NVM + Java 21/SDKMAN + Scala + uv/Python + Docker CLI + PlantUML server + Pi + pi-web + graphify
- `entrypoint.sh` — Container entrypoint (UID/GID mapping, Docker socket permissions, Pi package sync, graphify graph build, privilege drop)
- `web-entry.sh` — Installed as `pi-web-run`; starts pi-web's session daemon and server in the foreground
- `setup.sh` — Interactive first-time setup: tools, agents and plugins, completions, aliases, global symlink
- `examples/config.example` — Example user config (INI-style)
- `completions/{bash,zsh}.sh` — Shell completions
- `.dockerignore` — Only `entrypoint.sh` and `web-entry.sh` go into the image

## Build / Test / Lint Commands

```bash
./pi-web-dockerized.sh build          # Build Docker image (uses layer cache)
./pi-web-dockerized.sh run [DIR]      # Run Pi (default: current directory)
./pi-web-dockerized.sh web [DIR]      # Run pi-web
./pi-web-dockerized.sh update         # Cache-busting rebuild of Pi, pi-web and graphify
DRY_RUN=true ./pi-web-dockerized.sh run  # Print the docker command without running it

# Validation (no test framework exists — these are the only checks)
bash -n *.sh completions/bash.sh      # Syntax-check all scripts
shellcheck *.sh                       # Lint (shellcheck is not in the repo; install separately)

docker build -t pi-web-dockerized:latest .
docker run --rm pi-web-dockerized:latest pi --version
```

There are **no automated tests** — validate changes with `bash -n`, `shellcheck` and `DRY_RUN=true`. `DRY_RUN` still needs a reachable Docker daemon (`check_docker`).

## Code Style Guidelines

### Shell basics

- Executable scripts start with `#!/bin/bash` and `set -e`. **Exception:** `config-lib.sh` is sourced and must **not** use `set -e`. `entrypoint.sh` and `web-entry.sh` use `set -euo pipefail`.
- Resolve the script directory following symlinks: `SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"`, then `source "$SCRIPT_DIR/config-lib.sh"`.
- Naming: scripts `kebab-case.sh`, functions `snake_case`, constants and global arrays `UPPER_SNAKE`, locals `lower_snake`, booleans `FOO=false` compared with `= true`.
- Always quote variables, use `$()`, declare and assign separately (`local x; x=$(...)`, SC2155), `read -r`, and arrays for Docker args (`"${array[@]}"`) — never build docker arguments as strings.
- Colors/logging: `print_error/success/warning/info` in executables; `config-lib.sh` calls them through the `config_*` wrappers, which fall back to plain `echo`.
- Never splice host-derived values (paths, config values) into a `bash -c "..."` string: pass them as positional arguments or environment variables, as `entrypoint.sh` does for `WORKDIR`.

### Config file

INI-style, parsed in `load_config` with a `case` on the key:

```ini
setting.graphify_support=true
setting.web_port=8504
package.matt_pocock_skills=npm:pi-matt-pocock-skills
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
env.anthropic=ANTHROPIC_API_KEY
```

Boolean settings default to `false` and are enabled by an exact `=true`; opt-out settings (`graphify_support`, `plantuml_support`) default to `true` and are disabled by an exact `=false`. A new setting needs wiring in `config-lib.sh` in: the globals block, `load_config` (reset *and* case branch), `save_config`, `init_config_file`, a `prompt_*` function registered in `run_config_prompts`, and `print_config`. If the entrypoint acts on it, also add an `-e` entry in `build_common_docker_args`.

New Pi packages for `setup.sh` go into `PI_PACKAGE_CATALOG` (`key|source|description`). Sources must pass `valid_pi_source` (`npm:` or `git:`, no whitespace or shell metacharacters); the entrypoint re-validates them.

### Dockerfile conventions

- Base image pinned (`debian:bookworm-slim`); tool versions via `ARG`/`ENV`; apt cache cleaned in the same `RUN`.
- System packages as root; dev tools (NVM, SDKMAN, uv, Pi) as the non-root `coder` user. Docker CLI only, never the daemon.
- Everything that `update` should refresh sits **below** `ARG PI_BUILD_TIME`; slow, stable layers (JVM, Node, Python) sit above it.
- Global npm installs for Pi use `--ignore-scripts` (Pi's own recommendation); pi-web needs scripts for `node-pty`.

### Pi specifics to keep in mind

- Pi keeps *everything* in `~/.pi/agent` (`auth.json`, `settings.json`, sessions, trust decisions, installed packages), so it cannot be mounted read-only. The wrapper uses a private host directory by default; mounting the host's `~/.pi/agent` is an explicit opt-in (`setting.host_pi_config`).
- Project skills live in `.pi/skills` and `.agents/skills` and are trust-gated; global skills in `~/.pi/agent/skills` and `~/.agents/skills`. Prefer Pi packages (installed globally by the entrypoint) over writing into the project.
- The entrypoint only *adds* missing packages; it never removes any.
- Pi has no login subcommand: authentication is `/login` inside Pi, or provider API keys via `env.*`.

### Security rules

- Never commit `.env`, `auth.json`, `*.pem`, `*.key`, credentials.
- Docker socket: mount the host socket, no privileged mode, GID handled dynamically in `entrypoint.sh`.
- Run as non-root `coder` with UID/GID mapped to the host user; `--rm`; `--network host`.
- Custom user mounts default to read-only; environment variables reach the container only when listed as `env.*`, and only by name (`-e NAME`, so values never appear in `ps` or DRY_RUN output).
- pi-web has no authentication: default bind address is `127.0.0.1`.

## Volume Mounts Reference

See the table in `README.md`; it is built by `build_standard_volume_args` in `config-lib.sh`.
