#!/bin/sh
set -eu
probe=$(mktemp -d /run/ankole-fuse-probe.XXXXXX)
pid=
phase=device
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then echo "Drive mount probe failed during $phase (status $status)" >&2; fi
  umount "$probe/mount" 2>/dev/null || true
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$probe"
}
trap cleanup EXIT
test -c /dev/fuse
test "$(id -u)" = 0
mkdir "$probe/source" "$probe/mount"
phase=namespace
unshare --mount --pid --fork --mount-proc --propagation private \
  setpriv --reuid=1000 --regid=1000 --clear-groups --inh-caps=-all \
  --ambient-caps=-all --bounding-set=-all --no-new-privs true
ankole-rclone mount2 "$probe/source" "$probe/mount" --config /dev/null --vfs-cache-mode full --cache-dir "$probe/cache" &
pid=$!
phase=mount
attempt=0
until mountpoint -q "$probe/mount"; do
  kill -0 "$pid"
  attempt=$((attempt+1))
  # Match the mount manager's startup budget, including a cold binary launch.
  test "$attempt" -lt 150
  sleep 0.1
done
phase=read-write
printf 'fuse-ready' > "$probe/mount/probe"
test "$(cat "$probe/mount/probe")" = fuse-ready
