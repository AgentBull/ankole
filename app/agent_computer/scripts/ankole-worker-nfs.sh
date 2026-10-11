#!/usr/bin/env bash
# Mounts the shared NFS root before the Agent can start.
set -euo pipefail

test "$EUID" -eq 0
test -n "${ANKOLE_WORKER_NFS_SOURCE:?}"
mkdir -m 0700 -p /run/ankole-efs
mkdir -p /workspace

# EFS can have several mount targets. Block user-space NFS to every address,
# including a target added after this VM starts. The kernel mount uses root.
for family in -4 -6; do
  for protocol in tcp udp; do
    ip "$family" rule add priority 100 uidrange 1000-1000 ipproto "$protocol" dport 2049 prohibit
  done
done

mount -t nfs4 -o nfsvers=4.1,hard -- "$ANKOLE_WORKER_NFS_SOURCE" /run/ankole-efs
if [ "${ANKOLE_WORKER_TASK:-worker}" = delete_storage ]; then
  mount --bind /run/ankole-efs /workspace
else
  test ! -L "/run/ankole-efs/$WORKER_ID"
  mkdir -p "/run/ankole-efs/$WORKER_ID"
  chown 1000:1000 "/run/ankole-efs/$WORKER_ID"
  mount --bind "/run/ankole-efs/$WORKER_ID" /workspace
fi
umount /run/ankole-efs
