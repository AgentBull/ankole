# EventBus normalized CloudEvent

EventBus accepts decoded CloudEvents whose `data` field is the BullX normalized
MessageEvent payload. Channel Adapters own provider verification and provider
payload parsing; they normalize one provider occurrence into this common shape
before calling `BullX.EventBus.accept/2`.

This document is the schema source of truth for the normalized CloudEvent data
object. It is a data contract, not a new runtime entity, table, process, or
queue.

## Normalization chain

```text
provider occurrence
  -> Channel Adapter verifies and parses provider input
  -> adapter-normalized MessageEvent facts
  -> decoded CloudEvent with BullX normalized data
  -> BullX.EventBus.accept/2
```

The adapter-normalized MessageEvent stage is a boundary discipline: AIAgent,
Workflow, Command Target, EventBus matcher, and TargetSession code consume the
normalized CloudEvent only. They must not recover scene, mention, actor, scope,
or command facts from raw provider payloads.

## CloudEvents attributes

Accepted Events use CloudEvents structured JSON:

- `specversion` is `"1.0"`.
- `id`, `source`, and `type` are required non-empty strings.
- `time` is a required RFC3339 string for occurrence time.
- `datacontenttype` is `"application/json"`.
- `subject` is optional display/debug text and is not exposed to the matcher.
- `data` is the normalized payload defined below.

`source` and `id` form Event identity for acceptance dedupe. The adapter must
reuse the same `(source, id)` for provider redelivery of the same occurrence.

## Minimal shape

```json
{
  "specversion": "1.0",
  "id": "external-stable-event-id",
  "source": "feishu://main/tenant_xxx",
  "type": "bullx.im.message.addressed",
  "subject": "optional display text",
  "time": "2026-05-17T10:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "content": [
      {"type": "text", "text": "hello"}
    ],
    "channel": {
      "adapter": "feishu",
      "id": "main",
      "kind": "group"
    },
    "scope": {
      "id": "oc_xxx",
      "thread_id": null
    },
    "actor": {
      "external_account_id": "feishu:ou_xxx",
      "display_name": "Alice",
      "principal": {
        "id": "018f...",
        "type": "human"
      }
    },
    "refs": [
      {"kind": "feishu.message", "id": "om_xxx"}
    ],
    "reply_channel": {
      "adapter": "feishu",
      "channel_id": "main",
      "scope_id": "oc_xxx",
      "thread_id": null,
      "reply_to_external_id": "om_xxx",
      "reply_token_ref": null
    },
    "routing_facts": {
      "provider_event_type": "im.message.receive_v1",
      "content_kind": "text",
      "attention_reason": "mention"
    },
    "raw_ref": null
  }
}
```

## Data fields

| Field | Required | Nullable | Contract |
| --- | --- | --- | --- |
| `content` | yes | no | Non-empty list of normalized content parts. |
| `channel.adapter` | yes | no | Stable Channel Adapter id, such as `feishu`, `discord`, or `telegram`. |
| `channel.id` | yes | no | Adapter-local source id from plugin configuration. |
| `channel.kind` | yes | yes | `dm`, `group`, `webhook`, or `null`. Threading belongs to `scope.thread_id`. |
| `scope.id` | yes | no | Provider conversation, room, repository, object, or callback scope. |
| `scope.thread_id` | yes | yes | Provider thread dimension under `scope.id`, or `null`. |
| `actor.external_account_id` | yes | yes | Channel-local external actor id, such as `feishu:ou_xxx`, or `null` when the actor is already internal/system-only. |
| `actor.display_name` | yes | yes | Safe display name, or `null`. |
| `actor.principal` | yes | yes | Resolved BullX Principal summary, or `null`. |
| `refs` | yes | no | List of stable provider object references. Empty list is allowed. |
| `reply_channel` | yes | yes | Transport hint for possible replies or callbacks, or `null`. |
| `routing_facts` | yes | no | Matcher-oriented normalized facts. Empty object is allowed. |
| `raw_ref` | yes | yes | Provider raw reference or snapshot, or `null`. It is not a matcher surface. |

When `actor.principal` is present, it has this shape:

```json
{"id": "018f...", "type": "human"}
```

`actor.principal.id` is the string form of `principals.id`.
`actor.principal.type` follows the current Principal enum. V1 values are
`human` and `agent`. Adapters may set `actor.principal` only from Principal
subsystem results or another trusted BullX identity reference; they must not
invent Principal ids or Principal types from provider ids.

## Content parts

`content` follows the same discriminated style as `ReqLLM.Message.ContentPart`:
the `type` field chooses the content shape.

V1 adapters use these content part types:

| `type` | Required fields | Optional fields |
| --- | --- | --- |
| `text` | `text` | `metadata` |
| `image_url` | `url` | `media_type`, `metadata` |
| `video_url` | `url` | `media_type`, `metadata` |
| `image` | `data` | `media_type`, `filename`, `metadata`, `fallback_text` |
| `file` | `data` or `url` | `media_type`, `filename`, `metadata`, `fallback_text` |
| `card` | `format`, `payload` | `fallback_text`, `metadata` |

Audio, inline video, locations, stickers, and provider-specific rich objects use
`file`, `image`, `video_url`, or `card` until a concrete Target needs a sharper
content type.

The normalized schema allows inline `data` when the adapter has accepted and
normalized the content. Adapters may also use stable provider-local URIs or safe
references when inline content is not useful.

Machine-only Events may synthesize a short text content part so `content`
remains non-empty.

## Routing and storage policy

| Field | RoutingContext | May be copied into business records | Notes |
| --- | --- | --- | --- |
| `content` | no | yes, as Message content | The Target decides which content becomes business truth. |
| `channel` | yes | yes, as normalized metadata | `channel.kind` is a coarse scene hint, not provider taxonomy. |
| `scope` | yes | yes, as normalized metadata | Scope participates in conversation keys and TargetSession scope policy. |
| `actor` | yes | yes, as normalized metadata | External actor evidence is not permission. |
| `refs` | yes | yes, as normalized metadata | Keep stable provider object ids here. |
| `reply_channel` | yes | only as delivery hint or stable identity | It is not authorization. |
| `routing_facts` | yes | only allowlisted facts | Keep it small and matcher-oriented. |
| `raw_ref` | no | only when the owning layer wants it | It is not used for routing, scope, scene, mention, or AIAgent policy. |

`routing_facts` must not contain credentials, bearer-like tokens, arbitrary raw
payloads, unbounded message bodies, or provider SDK objects. Command arguments
do not belong in `routing_facts`; use normalized content or a command-specific
safe reference when a command design needs arguments.

Telemetry, logs, safe errors, Oban args, stream metadata, and public receipts
must use allowlisted metadata and must not copy credentials or bearer-like
tokens.

## Event types

IM message adapters use these normalized Event types:

- `bullx.im.message.addressed` for direct messages, group mentions, and
  provider-native directed interactions.
- `bullx.im.message.ambient` for observed group or channel messages that do not
  address BullX.

Command input uses `bullx.command.invoked` only when the provider command
surface or adapter command grammar accepts the input as a command. Ordinary text
that contains `/` remains a message Event.

Other normalized Event types, such as `bullx.message.edited`,
`bullx.reaction.changed`, `bullx.action.submitted`, `bullx.trigger.fired`, and
`bullx.childrun.completed`, are open-ended. EventBus validates the CloudEvents
shape and normalized data shape; it does not keep a provider event-name
allowlist.
