#!/usr/bin/env bash
# Establish the GitHub context from Ankole WorkerEnv without persisting credentials.

GH_AUTH_METHOD="none"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GH_USER=""
GH_OWNER=""
GH_REPO=""
GH_OWNER_REPO=""

if [ -n "$GITHUB_TOKEN" ] && command -v gh >/dev/null 2>&1; then
    if GH_USER=$(gh api user --jq '.login' 2>/dev/null) && [ -n "$GH_USER" ]; then
        GH_AUTH_METHOD="gh"
    else
        GH_USER=""
    fi
fi

_remote_url=$(git remote get-url origin 2>/dev/null)
if [ -n "$_remote_url" ] && printf '%s' "$_remote_url" | grep -q "github.com"; then
    GH_OWNER_REPO=$(printf '%s' "$_remote_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
    GH_OWNER=$(printf '%s' "$GH_OWNER_REPO" | cut -d/ -f1)
    GH_REPO=$(printf '%s' "$GH_OWNER_REPO" | cut -d/ -f2)
fi
unset _remote_url

printf 'GitHub Auth: %s\n' "$GH_AUTH_METHOD"
[ -n "$GH_USER" ] && printf 'User: %s\n' "$GH_USER"
[ -n "$GH_OWNER_REPO" ] && printf 'Repo: %s\n' "$GH_OWNER_REPO"
[ "$GH_AUTH_METHOD" = "none" ] &&
    printf '%s\n' 'GITHUB_TOKEN is missing or invalid, or GitHub CLI is unavailable.'

export GH_AUTH_METHOD GITHUB_TOKEN GH_USER GH_OWNER GH_REPO GH_OWNER_REPO
