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
# The unshared namespace starts with a copy of every Worker mount, including
# the Drive mounts of other views. A copy keeps that view's FUSE connection
# open, so the Worker's unmount of it would wait for this process tree to exit
# while rclone holds its global mount lock. Keep only this view's mounts.
# shortcut: mount keys are hex names, so mountinfo needs no octal unescaping.
awk -v root="$(dirname "$scope")/" -v scope="$scope" -v chat="$chat" -v library="$library" '
  index($5, root) != 1 { next }
  $5 == scope || index($5, scope "/") == 1 { next }
  $5 == chat || index($5, chat "/") == 1 { next }
  $5 == library || index($5, library "/") == 1 { next }
  { print $5 }
' /proc/self/mountinfo | sort -r | while read -r foreign; do
  # A parent detached earlier in this loop already removed its children.
  umount -l "$foreign" 2>/dev/null || :
done
exec "$@"
