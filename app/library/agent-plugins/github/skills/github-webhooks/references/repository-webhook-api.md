# Repository Webhook API

Use this reference after `github-auth` has set `GH_OWNER`, `GH_REPO`, and
`GITHUB_TOKEN`. These commands require GitHub CLI and repository Webhook
permission.

## Create

Set `EVENTS_JSON` to a JSON string array. Keep one hook for one delegation:

```bash
EVENTS_JSON='["issues","issue_comment"]'
HOOK_JSON=$(
  jq -n \
    --arg url "$CALLBACK_URL" \
    --argjson events "$EVENTS_JSON" \
    '{
      name: "web",
      active: true,
      events: $events,
      config: {
        url: $url,
        content_type: "json",
        insecure_ssl: "0"
      }
    }' |
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2026-03-10" \
      "repos/$GH_OWNER/$GH_REPO/hooks" \
      --input -
)
HOOK_ID=$(printf '%s' "$HOOK_JSON" | jq -er '.id')
unset HOOK_JSON
```

The response contains the capability URL. Keep it in memory only. GitHub sends
a `ping` delivery after creation.

## Inspect

Read the hook:

```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/$GH_OWNER/$GH_REPO/hooks/$HOOK_ID" \
  --jq 'del(.config.url)'
```

List recent deliveries:

```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/$GH_OWNER/$GH_REPO/hooks/$HOOK_ID/deliveries?per_page=100" \
  --jq '.[] | {id, guid, event, action, delivered_at, status, status_code, redelivery}'
```

A successful delivery has `status` equal to `OK`. Read one delivery when the
summary does not explain the failure:

```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/$GH_OWNER/$GH_REPO/hooks/$HOOK_ID/deliveries/$DELIVERY_ID" \
  --jq 'del(.url, .request.payload.hook.config.url)'
```

## Redeliver

GitHub does not automatically retry a failed delivery. A repository webhook
delivery from the last three days can be redelivered:

```bash
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/$GH_OWNER/$GH_REPO/hooks/$HOOK_ID/deliveries/$DELIVERY_ID/attempts"
```

The API returns HTTP 202 when it accepts the attempt. Inspect the delivery log
again and verify the current GitHub object before an external change.

## Find and delete

List repository hooks when creation had an uncertain result or a quota failed:

```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/$GH_OWNER/$GH_REPO/hooks?per_page=100" |
  jq --arg callback_url "$CALLBACK_URL" '
    .[] | {
      id,
      active,
      events,
      callback_matches: (.config.url == $callback_url),
      config: (.config | del(.url)),
      last_response
    }
  '
```

The hook URL is the Ankole ownership marker. `callback_matches` compares it
while the callback URL is still in memory, and the command keeps the URL out
of its output.

Delete the external hook before the Ankole endpoint:

```bash
gh api \
  --method DELETE \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/$GH_OWNER/$GH_REPO/hooks/$HOOK_ID"
```

GitHub returns HTTP 204 after deletion.

## GitHub contracts

- [Repository webhook REST API](https://docs.github.com/en/rest/repos/webhooks)
- [Creating webhooks](https://docs.github.com/en/webhooks/using-webhooks/creating-webhooks)
- [Handling failed deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries)
- [Redelivering webhooks](https://docs.github.com/en/webhooks/testing-and-troubleshooting-webhooks/redelivering-webhooks)
