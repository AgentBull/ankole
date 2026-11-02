#!/bin/sh
set -eu
# Only the root Worker supplies these paths; model processes receive the view.
scope=$1
chat=$2
recovery=$3
shift 3
mount -t tmpfs -o mode=0755,size=1m tmpfs /drive
for name in Public AgentDrive MyDrive; do
  if [ -d "$scope/$name" ]; then
    mkdir "/drive/$name"
    mount --bind "$scope/$name" "/drive/$name"
  fi
done
if [ "$chat" != - ]; then
  mkdir /drive/ChatDrive
  mount --bind "$chat" /drive/ChatDrive
fi
mount --bind "$recovery" /drive-recovery
exec "$@"
