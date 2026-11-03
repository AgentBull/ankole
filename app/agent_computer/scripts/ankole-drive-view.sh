#!/bin/sh
set -eu
# Only the root Worker supplies these paths; model processes receive the view.
scope=$1
chat=$2
recovery=$3
library=$4
shift 4
mount -t tmpfs -o mode=0755,size=1m tmpfs /drive
for name in Public AgentDrive MyDrive Brain; do
  if [ -d "$scope/$name" ]; then
    mkdir "/drive/$name"
    mount --bind "$scope/$name" "/drive/$name"
  fi
done
if [ "$chat" != - ]; then
  mkdir /drive/ChatDrive
  mount --bind "$chat" /drive/ChatDrive
fi
for name in Skills AGENTS.md DESIGN.md; do
  if [ -d "$library/$name" ]; then
    mkdir "/drive/$name"
  else
    touch "/drive/$name"
  fi
  mount --bind "$library/$name" "/drive/$name"
  mount -o remount,bind,ro "/drive/$name"
done
if [ -d /drive/Brain ]; then
  mount -o remount,bind,ro /drive/Brain
fi
mount --bind "$recovery" /drive-recovery
exec "$@"
