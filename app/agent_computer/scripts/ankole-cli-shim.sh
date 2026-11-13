#!/bin/sh
# Perceptual-shaping shim for the commands linked into /usr/local/libexec/ankole-cli-shims.
# Each link is named after the command it covers. The shim passes raw bytes through for
# ANKOLE_RAW=1, nested shim calls, forensics posture, and stdout that no longer points to
# the harness stream; otherwise it hands the call to the Bun shaper.
tool="${0##*/}"
shim_dir="${ANKOLE_SHIM_DIR_OVERRIDE:-/usr/local/libexec/ankole-cli-shims}"

passthrough() {
  # Callers such as Codex prepend their own directories, so the shim directory can sit
  # anywhere in PATH. Every entry of it must go, or exec resolves back to this shim.
  rest="${PATH}:"
  PATH=
  while [ -n "$rest" ]; do
    entry="${rest%%:*}"
    rest="${rest#*:}"
    if [ -n "$entry" ] && [ "$entry" != "$shim_dir" ]; then
      PATH="${PATH:+$PATH:}$entry"
    fi
  done
  exec "$tool" "$@"
}

if [ "${ANKOLE_RAW:-}" = "1" ] || [ "${ANKOLE_SHIM_ACTIVE:-}" = "1" ] || [ "${ANKOLE_PERCEPTUAL_POSTURE:-}" = "exact_data_forensics" ]; then
  passthrough "$@"
fi
if [ -n "${ANKOLE_HARNESS_STDOUT_ID:-}" ] && [ -L "/proc/$$/fd/1" ]; then
  if [ "$(/usr/bin/readlink "/proc/$$/fd/1" 2>/dev/null || true)" != "${ANKOLE_HARNESS_STDOUT_ID}" ]; then
    passthrough "$@"
  fi
fi
exec /usr/local/bin/bun /repo/app/agent_computer/src/cli/shim/ankole-cli-shim.ts "$tool" "$@"
