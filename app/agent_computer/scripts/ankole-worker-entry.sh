#!/usr/bin/env bash
# Prepares this Agent's persistent Home before any Worker process can write.
set -euo pipefail

# A launcher can replace the environment, for example sudo on Function Compute.
# Each variable that the image declares gets the image's value again. The
# contract and the other variables from the launcher stay.
while IFS= read -r -d '' variable; do export "$variable"; done < /etc/ankole/worker-environ

if [ "$EUID" -ne 0 ]; then
  echo 'Worker must start as root; model processes run as uid 1000' >&2
  exit 77
fi

if [ "${ANKOLE_WORKER_BOOTSTRAP:-}" = lambda ]; then
  echo 'Lambda bootstrap: starting Bun hooks' >&2
  exec bun /repo/app/agent_computer/src/worker/lambda-hooks.ts
fi
if [ "${ANKOLE_WORKER_BOOTSTRAP:-}" = function_compute ]; then
  exec bun /repo/app/agent_computer/src/worker/function-compute-bootstrap.ts
fi

if ! [[ "${WORKER_ID:-}" =~ ^[a-z0-9][a-z0-9._-]{0,95}$ ]]; then
  echo 'WORKER_ID must be a valid Agent UID' >&2
  exit 64
fi

if [ "${ANKOLE_WORKER_STORAGE:-}" = nfs ]; then
  /usr/local/bin/ankole-worker-nfs
fi

if [ "${ANKOLE_WORKER_TASK:-worker}" = delete_storage ]; then
  # The caller has confirmed that no Worker can write this shared directory.
  # Rename commits deletion. A retry also removes earlier incomplete removals.
  mkdir -p /workspace/.deleted
  if [ -e "/workspace/$WORKER_ID" ] || [ -L "/workspace/$WORKER_ID" ]; then
    mv -T -- "/workspace/$WORKER_ID" "/workspace/.deleted/$WORKER_ID-$(cat /proc/sys/kernel/random/uuid)"
  fi
  rm -rf -- /workspace/.deleted/*
  if [ "${ANKOLE_WORKER_STORAGE:-}" = nfs ]; then
    # Lambda reports RUNNING after this marker. Storage deletion must finish
    # before RUNNING can confirm deletion to the control plane.
    touch /run/ankole-entry-ready
  fi
  exit 0
fi

# As PID 1, bash ignores each signal that has no trap. A platform stops the
# container with SIGTERM, and the Cloudflare adapter can also send SIGUSR1.
# Until tini runs the supervisor, such a signal ends this script: no Worker
# starts, and no backup replaces the saved Home.
request=0
stop_before_worker() {
  if [ "$request" -ne 0 ]; then
    kill "$request" 2>/dev/null || true
  fi
  exit $((128 + $(kill -l "$1")))
}
for signal in TERM INT USR1; do
  trap "stop_before_worker $signal" "$signal"
done

case "${ANKOLE_WORKER_STORAGE:?}" in
  mounted|nfs) ;;
  adapter)
    # The instance disk is temporary, and a container restart replaces it.
    # This marker is on that disk, outside /workspace. It shows that the disk
    # holds the restored Home, and only then does the supervisor back it up.
    if [ ! -e /var/lib/ankole/agent-home-restored ]; then
      # A failed restore must not start a Worker or overwrite the saved Home.
      # The request runs in the background, so a trap can end it at once.
      curl --fail-with-body --silent --show-error --request POST \
        --header "Authorization: Bearer ${ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY:?}" \
        "${ANKOLE_WORKER_ADAPTER_URL:?}/agents/$WORKER_ID/storage/restore" &
      request=$!
      wait "$request"
      request=0
      mkdir -p /var/lib/ankole
      touch /var/lib/ankole/agent-home-restored
    fi
    ;;
  *) echo 'unsupported ANKOLE_WORKER_STORAGE' >&2; exit 64 ;;
esac

mkdir -p /workspace /var/cache/ankole
run_as_agent=(env -u ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY setpriv --reuid=1000 --regid=1000 --clear-groups --inh-caps=-all --ambient-caps=-all --no-new-privs)
# The platform can mount an empty /run over the image's runtime directory.
mkdir -p /run/ankole-browser
chown 1000:1000 /var/cache/ankole /run/ankole-browser
# OSS mounts permit writes by uid 1000 but do not support chown.
if ! "${run_as_agent[@]}" test -w /workspace; then
  chown 1000:1000 /workspace
fi
if [ -L "/agents/$WORKER_ID" ]; then
  test "$(readlink "/agents/$WORKER_ID")" = /workspace
else
  ln -sT /workspace "/agents/$WORKER_ID"
fi

"${run_as_agent[@]}" mkdir -p "$CODEX_HOME" "$CODEX_SQLITE_HOME"
if [ "$ANKOLE_WORKER_STORAGE" = nfs ]; then
  touch /run/ankole-entry-ready
fi
# Only model-driven children drop to uid 1000. The entry, supervisor, and
# Worker retain their separate identity and the generation credential.
exec tini -s -g -- ankole-worker-supervisor "$@"
