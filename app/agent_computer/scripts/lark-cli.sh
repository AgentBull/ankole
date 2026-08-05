#!/bin/sh
set -eu

readonly real_cli=/usr/local/libexec/lark-cli

# The image pins the CLI version and forbids self-update, so the per-command
# update/skills notices are pure noise in model-visible tool output.
export LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1
export LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1
readonly credential_file="${ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE:-}"
readonly max_age_seconds=300

credential_error() {
  printf '%s\n' '{"ok":false,"identity":"bot","error":{"type":"authentication","subtype":"credential_unavailable","code":"ankole_lark_credential_unavailable","message":"Ankole Lark credential is missing or stale"}}' >&2
  exit 3
}

if [ -n "${credential_file}" ]; then
  [ -r "${credential_file}" ] || credential_error
  modified_at="$(stat -c '%Y' -- "${credential_file}" 2>/dev/null)" || credential_error
  case "${modified_at}" in
    '' | *[!0-9]*) credential_error ;;
  esac

  now="$(date +%s)"
  [ "$((now - modified_at))" -le "${max_age_seconds}" ] || credential_error

  tenant_token=''
  IFS= read -r tenant_token < "${credential_file}" || [ -n "${tenant_token}" ] || credential_error
  [ -n "${tenant_token}" ] || credential_error
  export LARKSUITE_CLI_TENANT_ACCESS_TOKEN="${tenant_token}"
fi

exec "${real_cli}" "$@"
