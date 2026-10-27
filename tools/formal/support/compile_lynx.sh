#!/bin/sh
set -eu
patch=../../patches/lynx-map-iterator.patch
if ! git apply --reverse --check "$patch" 2>/dev/null; then
  git apply --check "$patch"
  git apply "$patch"
fi
MIX_ENV=prod mix compile
ln -sfn _build/prod/lib/lynx/ebin ebin
