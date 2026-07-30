---
name: github-webhooks
description: "Watch GitHub repository events over time with a webhook delegation that wakes the current Ankole Agent session."
default_enabled: false
category: github
tags: [GitHub, Webhooks, Delegation, Reconciliation]
version: 1.3.0
author: Ankole
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [GitHub, Webhooks, Delegation, Reconciliation]
    related_skills: [github-auth, github-issues, github-pr-workflow, github-repo-management]
---

# GitHub Webhook Delegation

The user's request supplies the repository, exact event set, expiry time, and
authorized response. One live delegation represents them with one Ankole
standing endpoint, one repository hook, and one reconciliation checkback.
GitHub filters the events. Ankole durably wakes the session that created the
endpoint.

Ankole webhook endpoints are a general capability with their own contract.
`create-webhook-cli --help` is the authoritative guide for that layer —
minting, modes, verification, lifecycle, and teardown. Read it before the
first `create-webhook-cli` call. This skill covers only what GitHub adds on
top: hook registration, ping verification, delivery reconciliation, and the
hook quota.

## Delegation boundary

Repository Webhook write permission is required. Select only the event names
needed by the task. The Ankole callback accepts at most 1 MiB; larger GitHub
deliveries fail with HTTP 413 and appear in delivery reconciliation.
Low-volume events such as `issues`, `issue_comment`, `pull_request`, and
`workflow_run` fit this v1 shape.

GitHub permits no more than 20 repository or organization hooks for one event
type. This contract uses one hook per delegation rather than an Ankole fan-out
layer.

## Endpoint and recovery state

Source `github-auth` and resolve the repository before external state exists:

```bash
source /repo/app/library/agent-plugins/github/skills/github-auth/scripts/gh-env.sh
test "$GH_AUTH_METHOD" = "gh"
test -n "$GH_OWNER_REPO"
```

GitHub delivers only to a public HTTPS callback URL, so the public HTTPS
ingress must be ready before endpoint creation. One shell keeps the returned
endpoint and callback URL until hook registration succeeds or rollback
finishes:

```bash
WEBHOOK_JSON=$(
  create-webhook-cli \
    --label "GitHub $GH_OWNER_REPO: <delegation>" \
    --mode standing \
    --expires-at "<ISO-8601>"
)
WEBHOOK_ENDPOINT_ID=$(printf '%s' "$WEBHOOK_JSON" | jq -er '.webhook_endpoint.id')
CALLBACK_URL=$(printf '%s' "$WEBHOOK_JSON" | jq -er '.webhook_endpoint.url')
case "$CALLBACK_URL" in
  https://*) ;;
  *)
    cancel-webhook-cli --id "$WEBHOOK_ENDPOINT_ID"
    unset CALLBACK_URL WEBHOOK_JSON
    exit 1
    ;;
esac
```

A `check_back_later` exists before the repository hook. Its durable context
contains the repository, endpoint ID, event set, expiry, and the obligation to
inspect deliveries, redeliver relevant failures, remove abandoned hooks, and
schedule the next check while the delegation is live.

The captured endpoint is reused after a later-step failure. If the shell loses
the callback URL, any external hook is removed and the old endpoint and
checkback are cancelled before one replacement endpoint is created.

## Repository hook and verification

[Repository Webhook API](references/repository-webhook-api.md) contains the
exact `gh api` calls. The hook uses JSON content, TLS verification, the exact
event set, and no webhook secret.

The checkback records the hook ID as soon as GitHub creates it. GitHub then
sends `ping`; setup is verified when the delivery log reports `OK`. An
uncertain create result is resolved by listing hooks and comparing the
in-memory callback URL without printing it. If no hook exists, the endpoint
and checkback are rollback state.

After verification, remove the plaintext shell values:

```bash
unset CALLBACK_URL WEBHOOK_JSON
```

## Receipt and reconciliation

`X-GitHub-Event`, `X-GitHub-Delivery`, and the bounded body identify the likely
object. A `ping` has no business effect. Other receipts lead to a current API
read, such as:

- `repos/{owner}/{repo}/issues/{number}`
- `repos/{owner}/{repo}/pulls/{number}`
- `repos/{owner}/{repo}/actions/runs/{run_id}`

At each checkback, the hook, expected event set, recent delivery log, current
GitHub objects, and next check time must agree. GitHub does not automatically
retry failed deliveries; relevant failures from the last three days use the
redelivery API. A quota error is resolved by identifying stale Ankole hooks,
not by adding a shared hook.

## Teardown

The GitHub hook is deleted first; a 404 already satisfies the external half:

```bash
gh api --method DELETE "repos/$GH_OWNER/$GH_REPO/hooks/$HOOK_ID"
cancel-webhook-cli --id "$WEBHOOK_ENDPOINT_ID"
```

The checkback is then cancelled. If GitHub deletion fails, the endpoint stays
active so the external hook does not point at a revoked capability. Terminal
state means the hook is absent, the endpoint is cancelled or expired, and no
reconciliation checkback remains.
