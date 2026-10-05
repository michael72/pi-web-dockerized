# Pi Web Dockerized

Run the [Pi coding agent](https://github.com/earendil-works/pi/tree/main/packages/coding-agent) — in the terminal or in the browser — inside a Docker container, so its blast radius is limited to the project directory you mount.

This is the Pi counterpart of [opencode-dockerized](https://github.com/michael72/opencode-dockerized): the same image toolbox (Python via `uv`, JVM + Scala + sbt via SDKMAN, Node via NVM, Docker CLI, PlantUML), the same `setup.sh` / wrapper-script workflow, with the agent swapped for Pi.

- **Terminal:** `pi-web-dockerized run [DIR]`
- **Browser:** `pi-web-dockerized web [DIR]` serves [pi-web](https://github.com/jmfederico/pi-web) on <http://127.0.0.1:8504>
- **Choose your extras:** `setup.sh` offers tools (Graphify, PlantUML, SSH agent), agents and plugins (Pi packages such as [pi-matt-pocock-skills](https://pi.dev/packages/pi-matt-pocock-skills))

## Quick start

```bash
./setup.sh                          # choose tools, agents and plugins; installs completions/aliases
pi-web-dockerized build             # build the image (first build takes a while: JVM, Node, native modules)
pi-web-dockerized auth              # sign in: type /login in Pi, pick a provider, /quit
pi-web-dockerized run ~/my/project  # terminal UI
pi-web-dockerized web ~/my/project  # or: browser UI
```

Without `setup.sh`'s global install, call `./pi-web-dockerized.sh` directly. Docker must be running.

Instead of `/login` you can pass provider keys as environment variables — add an `env.*` entry (see [Configuration](#configuration)), e.g. `env.anthropic=ANTHROPIC_API_KEY`. Only the variable *name* goes into the config; Docker reads the value from your shell.

## Commands

| Command | What it does |
|---|---|
| `run [DIR]` | Pi in the terminal, project mounted read-write (default: current directory) |
| `web [DIR]` | pi-web browser UI. `DIR` can be one project or a folder of projects |
| `auth` | Starts Pi without a project so you can `/login` |
| `models [SEARCH]` | List the models your providers offer |
| `exec MSG` | Non-interactive prompt (`pi -p`), output is pipeable |
| `pkg [list\|install\|remove\|update\|config]` | Manage Pi packages |
| `shell [DIR]` | Bash in the container |
| `build` / `update` | Build the image / rebuild with the latest Pi, pi-web and graphify |
| `version`, `config [show\|edit\|path]`, `clean`, `help` | |

`DRY_RUN=true pi-web-dockerized run` prints the `docker run` command instead of executing it. `setup.sh` also offers the aliases `pid`, `pid-run`, `pid-web` and `pid-auth`.

## Tools, agents and plugins

`setup.sh` asks about each of these and stores the answers in `~/.config/pi-web-dockerized/config`. Re-run it any time, or edit the file (`pi-web-dockerized config edit`; see [examples/config.example](examples/config.example)).

### Pi packages (skills, agents, extensions)

Pi packages are installed with `pi install` on first launch into the container's agent directory, so the download happens once. Offered by `setup.sh`:

| Package | Adds |
|---|---|
| [`pi-matt-pocock-skills`](https://pi.dev/packages/pi-matt-pocock-skills) | Matt Pocock's engineering skills (`/grilling`, `/to-spec`, `/to-tickets`, `/implement`, `/code-review`, `/tdd`, `/wayfinder`, …), a `subagent` tool, five agents (scout, planner, implementer, standards- and spec-reviewer) and three workflow prompts. Run `/setup-matt-pocock-skills` once per repository. Unofficial port of [mattpocock/skills](https://github.com/mattpocock/skills) |
| `pi-subagents` | Single-agent delegation and scripted multi-agent workflows — may overlap with the subagent tool above, pick one |
| `pi-web-access` | Web search, URL fetching, GitHub cloning, PDF extraction |
| `pi-lens` | LSP, linters, formatters, type checking feedback |
| `@juicesharp/rpiv-ask-user-question`, `@juicesharp/rpiv-todo` | Structured questions, a todo overlay |
| `pi-background-tasks` | Durable background shell tasks |

Any other package works too: `package.<name>=npm:<pkg>[@version]` or `git:<host>/<repo>[@ref]` in the config, or enter it when `setup.sh` asks. Browse [pi.dev/packages](https://pi.dev/packages).

- Packages are unpinned by default. They run with the container's permissions and see your project and credentials: review them, and pin a version (`npm:pi-matt-pocock-skills@0.2.0`) if you want reproducible installs.
- Removing a package from the config does not uninstall it. Use `pi-web-dockerized pkg remove <source>` (the entry in the config has to go too, or it is installed again on the next launch).

### Graphify — does it work with Pi?

Yes. Graphify supports Pi (`graphify pi install` writes a skill to `~/.pi/agent/skills/graphify`), and there is a maintained Pi package, [`graphify-pi`](https://github.com/juhas96/graphify-pi), that goes further than a skill: it injects graph-first guidance into Pi's system prompt whenever `graphify-out/` exists, flags a stale graph, and adds `/graphify`.

With `setting.graphify_support=true` (the default) the container

1. installs `graphify-pi` (once),
2. for `run` and `exec`: builds `<project>/graphify-out/` on first launch (`graphify . --code-only`, local AST extraction — no API key, no network) and refreshes it incrementally on every later launch.

Communities stay unnamed ("Community N") because the startup build uses no LLM; run `/graphify label .` in Pi once a provider is configured. Add `graphify-out/` to the project's `.gitignore` unless you want to commit it. In `web` mode no graph is built at startup (projects are only chosen in the browser); use `/graphify .` in a session.

### Other tools

| Setting | Default | Meaning |
|---|---|---|
| `setting.graphify_support` | `true` | See above |
| `setting.plantuml_support` | `true` | Start the `pumlsrv` PlantUML server for `pumlcli` |
| `setting.ssh_agent_support` | `false` | Forward the host's `SSH_AUTH_SOCK` (git over SSH without sharing keys) |
| `setting.web_host` / `setting.web_port` | `127.0.0.1` / `8504` | Where `web` listens |
| `setting.host_pi_config` | `false` | Use the host's `~/.pi/agent` — see [Security](#security) |

Not carried over from opencode-dockerized: the LLM-interceptor (`lli`) integration and Oh My OpenCode specifics (Bun was dropped from the image with it).

## The web UI

`web` starts pi-web's session daemon and server in the container. Pi sessions keep running when the browser disconnects, as long as the container runs (Ctrl-C stops it). The wrapper prints the path to add as a project in the UI: the project is mounted at its host path with `$HOME` stripped (`/home/me/code/app` → `/code/app`).

pi-web has **no authentication** and assumes trusted users. The default bind address `127.0.0.1` combined with `--network host` makes it reachable from your machine only. To use it from another device, change `setting.web_host` only on a network you trust, or tunnel with SSH / an authenticated reverse proxy. Its state (projects, settings) persists in `~/.local/share/pi-web-dockerized/pi-web/`.

## Configuration

`~/.config/pi-web-dockerized/config` is an INI-style file:

```ini
setting.graphify_support=true
package.matt_pocock_skills=npm:pi-matt-pocock-skills
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig       # read-only unless :rw
env.anthropic=ANTHROPIC_API_KEY                           # passes the host variable through
```

## Security

Pi runs commands **without asking for approval**, and its extensions run with the same permissions. The container is the safety boundary, and what you mount decides how strong it is:

- **Project directory: read-write.** That is the blast radius for file changes. Git worktrees get the main `.git` directory read-only, so `git commit` must be done on the host.
- **Private agent directory.** Pi's [containerization guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md) advises against mounting `~/.pi/agent`. The container therefore uses `~/.local/share/pi-web-dockerized/agent` (credentials from `/login`, settings, sessions, installed packages), created with mode 700. `setting.host_pi_config=true` mounts your host `~/.pi/agent` read-write instead — convenient, but then anything running in the container can read your host credentials and rewrite your host extensions.
- **Docker socket is mounted** for Docker-in-Docker work. That gives the container control over the host's Docker daemon, i.e. effectively root on the host. If you do not need it, pass `false` as the `docker_socket` argument in the `run_container` calls of `pi-web-dockerized.sh`.
- **Network is the host's** (`--network host`) — no egress restriction.
- **Project trust.** Pi asks before loading `.pi/` or `.agents/skills` resources from a project; the decision is saved in the agent directory (`trust.json`). Treat an unfamiliar repository's `AGENTS.md` as untrusted input regardless.
- Non-root user mapped to your host UID/GID; `--rm` removes containers on exit; `~/.gitconfig`, `~/.npmrc`, `~/.agents` and `~/.gradle/gradle.properties` are mounted read-only.
- Environment variables reach the container only when listed as `env.*`, and only by name.

## Volume mounts

| Host path | Container path | Mode | Purpose |
|---|---|---|---|
| project (`DIR`) | `DIR` with `$HOME` stripped | rw | Project files |
| `~/.local/share/pi-web-dockerized/agent` (or `~/.pi/agent`) | `/home/coder/.pi/agent` | rw | Credentials, settings, sessions, Pi packages |
| `~/.local/share/pi-web-dockerized/pi-web/{config,data}` | `~/.config/pi-web`, `~/.pi-web` | rw | pi-web state |
| `~/.gradle`, `~/.m2`, `~/.npm` | same under `/home/coder` | rw | Build and package caches |
| `~/.gradle/gradle.properties`, `~/.gitconfig`, `~/.npmrc`, `~/.agents` | same under `/home/coder` | ro | Credentials, git identity, shared skills (`~/.agents/skills`) |
| `/var/run/docker.sock` | same | rw | Docker socket (`run`, `web`, `exec`, `shell`) |
| custom `mount.*` entries | as configured | ro / rw | Whatever you add |

## Updating

`pi-web-dockerized update` rebuilds the image with the latest Pi, pi-web and graphify (the cache is busted from the `PI_BUILD_TIME` layer on; JVM, Node and Python layers are reused). Update installed Pi packages with `pi-web-dockerized pkg update`.

## Troubleshooting

- **`pi list` shows a `…/pi-web/dist/pi-packages/relays` entry.** Running `web` makes pi-web register its own relay package in Pi's settings, by path into the image's global `node_modules`. After an image update that changes that path (for example a new Node version) Pi may warn about a missing package; remove the stale entry with `pi-web-dockerized pkg remove <path>` and start `web` again.
- **Port already in use.** A host-side pi-web service already owns 8504; change `setting.web_port` (`setup.sh` or the config).
- **First launch is slow.** Package installs (and the graphify build for big projects) happen then; later launches skip the installs. Set `setting.graphify_support=false` to skip graph builds.
- **Files owned by root in the project.** Should not happen — the container maps your UID/GID. If it does, check that `HOST_UID`/`HOST_GID` reach the container (`DRY_RUN=true`).
- `--network host` behaves differently on Docker Desktop for macOS/Windows; `web` may then need a port mapping instead.

## License

MIT, see [LICENSE](LICENSE).
