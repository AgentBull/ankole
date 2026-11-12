#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ ${1:-} != --test ]]; then
  output=${1:?output binary path}
  arch=${2:?amd64 or arm64}
  case "$arch" in amd64|arm64) ;; *) exit 64 ;; esac
fi
build_root=$(mktemp -d)
trap 'rm -rf "$build_root"' EXIT
git clone --quiet --depth 1 --branch v1.75.2 https://github.com/rclone/rclone.git "$build_root"
git -C "$build_root" apply "$source_root/ankole.patch"
cp -R "$source_root/overlay/." "$build_root/"
cd "$build_root"
if [[ $1 == --test ]]; then
  packages=(. ./internal/ankole ./backend/webdav ./backend/webdav/api ./cmd/mount2 ./cmd/mountlib ./fs ./vfs ./vfs/vfscache ./vfs/vfscache/writeback)
  go vet -tags ankole "${packages[@]}"
  # Ankole's DAV and native mount integration runs against the complete Worker
  # image in control_plane/test/ankole/files/vfs_test.exs. These upstream cases
  # start other DAV products or expect a separately installed FUSE helper.
  go test -race -tags ankole -skip '^Test(Integration[0-9]*|Mount)$' . ./internal/ankole ./backend/webdav ./backend/webdav/api ./cmd/mount2 ./fs ./vfs ./vfs/vfscache/writeback
  go test -race -tags ankole ./cmd/mountlib -run TestAnkole
  go test -race -tags ankole ./vfs/vfscache -run "TestProviderCapacity|TestAnkole"
else
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -tags ankole -ldflags '-s -w -X github.com/rclone/rclone/fs.Version=v1.75.2-ankole' -o "$output" .
fi
