#!/bin/bash
set -euo pipefail

# Runs pi-web (browser UI for Pi sessions) in the foreground inside the container.
# Installed as /usr/local/bin/pi-web-run and started via entrypoint.sh, i.e. as the
# mapped host user with NVM already sourced.
#
# 'pi-web install' sets pi-web up as per-user systemd/launchd services, which do not
# exist in a container. The two processes it would manage are started directly:
#   pi-web-sessiond  keeps Pi sessions alive, independent of the browser
#   pi-web-server    HTTP + WebSocket gateway serving the UI

export PI_WEB_HOST="${PI_WEB_HOST:-127.0.0.1}"
export PI_WEB_PORT="${PI_WEB_PORT:-8504}"

pi-web-sessiond &
sessiond_pid=$!
server_pid=""

# Forward 'docker stop' (SIGTERM) and Ctrl-C to both processes; bash would otherwise
# only act on the signal once its foreground child had exited.
stop_all() {
    kill "$sessiond_pid" ${server_pid:+"$server_pid"} 2>/dev/null || true
}
trap stop_all TERM INT EXIT

# The server needs the session daemon's socket, which appears shortly after start
sleep 3
if ! kill -0 "$sessiond_pid" 2>/dev/null; then
    echo "pi-web: session daemon exited during startup" >&2
    exit 1
fi

echo "pi-web: listening on http://${PI_WEB_HOST}:${PI_WEB_PORT}"
pi-web-server &
server_pid=$!
wait "$server_pid"
