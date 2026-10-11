#!/usr/bin/env bash
# Starts one Worker entry when the platform uses a command API.
set -euo pipefail

# The PID file also records that this instance has received its entry. Keep
# it after exit: a delayed command must not start another Worker after a
# supervisor crash. Both files are in the root-owned runtime directory.
exec flock -n --close /run/ankole-worker.lock bash -ec '
  if [ -e /run/ankole-worker.pid ]; then exit 0; fi
  echo $$ > /run/ankole-worker.pid
  exec /usr/local/bin/ankole-worker-entry "$@"
' -- "$@"
