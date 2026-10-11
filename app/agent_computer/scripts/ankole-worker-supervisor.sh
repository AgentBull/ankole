#!/usr/bin/env bash
# Runs the Agent Computer Worker and starts it again in place after a failure.
#
# Usage: ankole-worker-supervisor COMMAND [ARG...]
#
# - The Worker exits 0 after a drain. The supervisor then exits 0, and the
#   container stops.
# - Any other exit is a failure: a crash, self-isolation, or a binding
#   violation. The supervisor ends the processes that the failed Worker left
#   and starts the Worker again after 1, 2, 4, ... seconds, up to 60 seconds.
#   A run that lasts 60 seconds or more sets the delay back to 1 second.
# - SIGTERM and SIGINT go to the Worker process one time. The Worker stops
#   its own child processes in order, for example the browser daemon after
#   the drain. The supervisor then waits for the Worker and exits with its
#   status. It does not start the Worker again.
#
# The Worker runs in its own session. Thus the group signal from `tini -g`
# reaches only the supervisor, and the Worker gets each signal one time.
set -u

if [ "$#" -eq 0 ]; then
  echo 'usage: ankole-worker-supervisor COMMAND [ARG...]' >&2
  exit 64
fi

readonly max_delay=60
delay=1
stopping=0
worker=0
status=0

stop() {
  stopping=1
  if [ "$worker" -ne 0 ]; then
    kill -s "$1" "$worker" 2>/dev/null || true
  fi
}
trap 'stop TERM' TERM
trap 'stop INT' INT
trap 'stopping=1; end_leftover_processes; if [ "$worker" -ne 0 ]; then kill -KILL "$worker" 2>/dev/null || true; fi' USR1

# Ends the Agent user's processes. Old commands,
# Codex, and browser processes must not write beside the next Worker. Tini
# can be a child of a platform command service instead of PID 1. Its subreaper
# flag reaps the orphaned processes in both cases. This requires a private
# PID namespace. A direct test or manual run without tini skips this step.
end_leftover_processes() {
  if [ "$(cat "/proc/$PPID/comm" 2>/dev/null)" = tini ]; then
    # SIGKILL is a request. A task blocked in disk I/O can still write until
    # it exits. Do not restart or back up while such a task remains.
    while kill_remaining_writers; do sleep 0.05; done
  fi
}

kill_remaining_writers() {
  local file pid state uid key value rest remaining=1
  for file in /proc/[0-9]*/status; do
    pid=${file#/proc/}; pid=${pid%/status}
    [ "$pid" = 1 ] || [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] && continue
    state= uid=
    while read -r key value rest; do
      case "$key" in State:) state=$value ;; Uid:) uid=$value ;; esac
    done < "$file" 2>/dev/null || continue
    # A spawn can still be in setpriv when the Worker exits. End that root
    # wrapper too, before it can start another Agent process after this sweep.
    if { [ "$uid" = 1000 ] || { [ "$uid" = 0 ] && [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = /usr/bin/setpriv ]; }; } &&
      [ "$state" != Z ] && [ "$state" != X ]; then
      remaining=0
      kill -s KILL "$pid" 2>/dev/null || true
    fi
  done
  return "$remaining"
}

finish() {
  end_leftover_processes
  if [ "${ANKOLE_WORKER_STORAGE:-mounted}" = adapter ]; then
    # The entrypoint writes this marker after it restores Agent Home on this
    # instance disk. A backup of any other Home would replace the saved one.
    if [ ! -e /var/lib/ankole/agent-home-restored ]; then
      echo 'Agent Home was not restored on this disk; no backup' >&2
      exit 1
    fi
    if ! curl --fail-with-body --silent --show-error --request POST \
      --header "Authorization: Bearer ${ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY:?}" \
      "${ANKOLE_WORKER_ADAPTER_URL:?}/agents/${WORKER_ID:?}/storage/backup"; then
      echo 'Agent Home backup failed' >&2
      exit 1
    fi
  fi
  exit "$status"
}

log_restart() {
  printf '{"severity":"WARNING","time":"%s","event":"worker.restart_scheduled","exit_status":%d,"delay_seconds":%d,"labels":{"service":"ankole-worker","component":"worker-supervisor"},"message":"worker exited; starting it again"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$status" "$delay" >&2
}

while :; do
  started=$SECONDS
  setsid "$@" &
  worker=$!
  # A trapped signal stops `wait` early while the Worker still runs. Wait
  # again until the Worker has exited.
  while :; do
    wait "$worker"
    status=$?
    kill -0 "$worker" 2>/dev/null || break
  done
  worker=0

  if [ "$status" -eq 0 ] || [ "$stopping" -eq 1 ]; then
    finish
  fi

  end_leftover_processes
  if [ $((SECONDS - started)) -ge "$max_delay" ]; then
    delay=1
  fi
  log_restart
  sleep "$delay" &
  sleeper=$!
  # A trapped signal stops the delay early.
  wait "$sleeper"
  kill "$sleeper" 2>/dev/null || true
  if [ "$stopping" -eq 1 ]; then
    finish
  fi
  delay=$((delay * 2))
  if [ "$delay" -gt "$max_delay" ]; then
    delay=$max_delay
  fi
done
