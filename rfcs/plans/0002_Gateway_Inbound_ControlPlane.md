# RFC 0002: Gateway Inbound + ControlPlane

- **Author**: Boris Ding
- **Created**: 2026-04-22
- **Supersedes**: `rfcs/drafts/Gateway.md` (jointly with RFC 0003)

## 1. TL;DR

BullX Gateway is the OTP-based, durable ingress and egress layer for external messaging. The Gateway answers exactly two questions:

1. *"Something happened in the outside world; how does it become an internal BullX input signal?"*
2. *"Runtime wants to send something outwards; how does it reach the right external channel?"*

This RFC owns the **inbound carrier path** and the **ControlPlane** that durably backs it. The matching egress effects path — `Dispatcher`, `ScopeWorker`, retry / DLQ / replay, outbound dedupe — is owned by RFC 0003. Both RFCs share a single supervision tree, a single ControlPlane, a single content shape, and a single policy pipeline.

Key inbound design:

1. **Single inbound carrier with `event`.** Every inbound event is published as `signal.type = "com.agentbull.x.inbound.received"`. Gateway owns a 7-value semantic axis at `data.event.type` — `message` / `message_edited` / `message_recalled` / `reaction` / `action` / `slash_command` / `trigger` — and derives a `data.duplex` boolean from it (six chat-style types are duplex, `trigger` is not).
2. **Content-first contract.** Every inbound signal carries a non-empty `content` list. There is no top-level summary string. When a source has no native multimodal body (reaction, recall, some action flows), the adapter or Gateway synthesizes a single `text` block. When a source is naturally multimodal, `content` may be image / file / audio / card without any parallel summary field.
3. **Adapter-owned concrete event + Gateway-owned semantic type.** Gateway Core models the carrier and `event.type`; adapters model `event.name` + `event.data` (for example `event.name = "feishu.message.posted"` or `"github.issue.opened"`). Gateway does not enumerate, validate, or interpret adapter event domain fields.
4. **Ack-after-publish dedupe.** Gateway publishes the rendered signal to `Jido.Signal.Bus`, marks `(source, id)` in `gateway_dedupe_seen` (UNLOGGED + ETS hot cache), and then returns to the adapter. A `Bus.publish` failure returns an error so the external source can retry. There is no in-flight persistence of the inbound envelope.
5. **Policy pipeline.** Gateway exposes pluggable `Gating`, `Moderation`, `Security` behaviours, modelled after `jido_messaging`. Defaults are empty. The pipeline order (`Security → Dedupe → Gating → Moderation → Bus publish → mark_seen`) is fixed by Gateway; the modules are supplied by the application.
6. **Flat scope model.** Gateway does not introduce `%Room{}` / `%Participant{}` / `%Thread{}` / `%RoomBinding{}` / `%RoutingPolicy{}`. The flat `{channel, scope_id, thread_id, actor, refs}` shape covers every IM / webhook scenario examined; chat-business aggregation is Runtime's job.

The egress half is summarised at the boundary (see RFC 0003) and only as much as this document needs to define the supervision tree, the `Adapter` behaviour, the Store callbacks, and the policy pipeline.

### 1.1 Cleanup plan

- **Dead code to delete**
  - Delete the placeholder `BullXGateway.CoreSupervisor` once `BullXGateway.CoreSupervisor` and `BullXGateway.AdapterSupervisor` are wired into `BullX.Application`.
  - Delete the old "Gateway boots with zero children" application test assumption; Gateway will now own concrete infrastructure children.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse the existing subsystem supervisor pattern already used by `BullX.Config.Supervisor`, `BullX.Runtime.Supervisor`, `BullXBrain.Supervisor`, and `BullX.Skills.Supervisor`.
  - Reuse `BullX.Repo` + Ecto sandbox for all durable Gateway tests; do not add an ETS-only store variant.
  - Reuse `Jido.Signal` / `Jido.Signal.Bus` directly for the carrier instead of inventing a BullX-local signal envelope or bus abstraction.
- **Actual code paths / processes / schemas changing**
  - Add the inbound Gateway runtime path: `BullX.Gateway.publish_inbound/1` -> `InboundReceived` -> `Security` -> `Deduper` -> `Gating` -> `Moderation` -> `Jido.Signal.Bus.publish/2` -> `Deduper.mark_seen`.
  - Replace the empty Gateway supervisor with `CoreSupervisor` + `AdapterSupervisor` and move application startup order to `Repo -> Config -> Gateway.CoreSupervisor -> Skills -> Brain -> Runtime -> Gateway.AdapterSupervisor -> Endpoint`.
  - Add the inbound durable schema `gateway_dedupe_seen` plus its Ecto wrapper.
  - Extend the adapter contract with a side-effect-light connectivity check used by setup/control-plane writes before a configured adapter is persisted.
  - Add a Gateway-owned adapter-config codec for database-backed `config :bullx, :gateway, adapters` values, so Setup can write complex adapter arrays without teaching BullXWeb how to build runtime tuples.
- **Invariants that must remain true**
  - Gateway Core still must not model business-domain events or parse `event.data`.
  - Inbound dedupe is `(source, id)` based and `mark_seen` happens only after Bus publish succeeds.
  - `Gateway` code must stay independent of `Plug.Conn`; only `Webhook.RawBodyReader` may touch Plug types.
  - The final published inbound signal must be JSON-neutral, string-keyed, and always carry non-empty `content` plus `event`.
  - Setup/control-plane adapter writes must not start adapter children, publish signals, consume activation codes, or mutate account state.
  - A persisted adapter array is accepted only after every enabled adapter entry has a fresh successful connectivity check for the exact submitted entry fingerprint.
- **Verification commands**
  - `mix test test/bullx/application_test.exs test/bullx_gateway`
  - `mix precommit`

## 2. Position and boundaries

### 2.1 What Gateway Core does

1. Hosts `BullXGateway.SignalBus` (a `Jido.Signal.Bus` instance).
2. Provides `BullX.Gateway.publish_inbound/1`: an adapter constructs one of the seven `BullXGateway.Inputs.*` canonical structs, hands it to Gateway, Gateway renders it into a `%Jido.Signal{}` and publishes.
3. Provides `BullX.Gateway.deliver/1` and `BullX.Gateway.cancel_stream/1` — full semantics in RFC 0003.
4. Provides DLQ ops API `list_dead_letters/1` / `replay_dead_letter/1` — full semantics in RFC 0003.
5. Maintains `AdapterRegistry`, mapping `{adapter, channel_id}` to an adapter module, config, and retry policy.
6. **ControlPlane**: durable writes to `gateway_dedupe_seen` (UNLOGGED, this RFC) and `gateway_dead_letters` (UNLOGGED, RFC 0003). These are the only two Gateway tables.
7. Maintains per-scope `ScopeWorker` processes for outbound serialization (RFC 0003).
8. Performs `(source, id)` inbound dedupe (ETS hot cache + `gateway_dedupe_seen` UNLOGGED backing, per-adapter TTL).
9. Performs `delivery.id` outbound dedupe (RFC 0003).
10. Runs the policy pipeline hooks defined in §6.8.
11. Emits telemetry: publish failed / adapter crashed / queue length / delivery succeeded / failed / pipeline decisions.
12. Provides a control-plane adapter configuration boundary: parse/validate a database-backed adapter array, convert it to runtime adapter specs, and run adapter connectivity checks before setup saves.

### 2.2 What Gateway Core explicitly does not do (cross-cutting non-goals)

- Does not model business events. GitHub issues, Stripe payments, Kafka offsets, market ticks, Feishu domain payloads — all owned by adapters. Gateway transports `event` with opaque `event.data`.
- Does not define a generic `WebhookRequest`, does not enforce a signature framework, does not touch raw body / headers / query / remote IP. The single exception is `BullXGateway.Webhook.RawBodyReader` (§6.6), a body-reader helper.
- Does not own session, turn, memory, knowledge, budget, approval, HITL, cron, subagent, agent orchestration, or "interrupt agent on new message" concurrency. Those belong to Runtime.
- Does not introduce `%Room{}` / `%Participant{}` / `%Thread{}` / `%RoomBinding{}` / `%RoutingPolicy{}`. No thread lifecycle, participant registry, presence, or typing.
- Does not model platform-specific semantics like `ModalClose` or `AssistantThreadStarted`.
- Does not maintain media long-term storage or a unified media cache; adapters handle that.
- Does not filter think-blocks or reasoning content (Runtime).
- Does not enumerate `failure_class` / retry taxonomy as a protocol contract. `error.kind` is supplied by adapters; Runtime decides retry semantics for itself.
- Does not perform cross-node routing, distributed bus, or global consistency.
- Does not perform audit-grade rejection persistence (rejections go to telemetry only).
- Does not attempt mid-stream durability (only the `stream_close` outcome is durable; see RFC 0003).
- Does not ship default Gating / Moderation / Security implementations; the application layer provides them.
- Does not own the Setup UI. BullXWeb renders the Inertia application and calls Gateway's adapter-config and connectivity boundary; Gateway owns only the adapter contract and runtime shape.
- Does not persist or echo plaintext secrets outside `app_configs`. Adapter connectivity result payloads must be safe to log or render and must never contain app secrets, tokens, webhook bodies, or OAuth codes.

### 2.3 Inbound-focused do / don't

**Do (this RFC):**

- Render canonical `%Jido.Signal{}` envelopes with the `content + event` contract.
- Validate carrier shape, never event-domain semantics.
- Record `(source, id)` dedupe in `gateway_dedupe_seen` only after a successful Bus publish.
- Run the inbound policy pipeline (`Security → Dedupe → Gating → Moderation → Bus publish → mark_seen`).
- Return `{:error, {:bus_publish_failed, _}}` on Bus errors so the external source can retry.

**Don't (this RFC):**

- Don't validate `event.data` field-by-field.
- Don't whitelist `event.name` values.
- Don't persist a per-event audit row for rejections or in-flight signals — `Security` / `Gating` / `Moderation` denials and Bus-publish failures live in telemetry and the synchronous return value only. The external source retries on error; a successful retry publishes normally.
- Don't introduce a BullX-user-system identity slot on `actor`; Runtime maps `actor.id` to business identity when needed.
- Don't subscribe to the Bus with persistent / ack-checkpointing semantics; the carrier is pure publish / subscribe.

## 3. Design constraints

The eleven constraints that frame the Gateway design as a whole:

1. **Single node.** No cross-node routing, no distributed bus, no global consistency.
2. **PostgreSQL is required.** Gateway uses `BullX.Repo` (PostgreSQL) for dedupe backing and the DLQ. Both Gateway tables (`gateway_dedupe_seen`, `gateway_dead_letters`) are `UNLOGGED` — their loss on unclean server crash is recoverable (external sources retry; Runtime + Oban re-dispatches outbound). dev / test go through the Ecto sandbox; no ETS-only backend is maintained.
3. **Process isolation.** A single channel / scope / listener failure must not propagate to the rest of Gateway.
4. **New channel = incremental extension.** Adding an adapter must not change the Gateway Core protocol or the supervision tree skeleton.
5. **Inbound uses `Jido.Signal`.** No second event envelope is invented.
6. **Outbound uses a separate `BullXGateway.Delivery` struct.** Inbound and outbound are not stuffed into one type.
7. **Bus routing is by `signal.type` pattern.** `Jido.Signal.Bus.subscribe/3` is the real semantics; there is no parallel topic-PubSub.
8. **`time` is an ISO8601 string; `specversion` must be exactly `"1.0.2"`.** See Appendix A.
9. **Gateway-produced signals prefer the external stable event id as `signal.id`.** When omitted, `Jido.Signal.new/1` generates a UUID7.
10. **No persistent / ack-checkpoint Bus subscriptions.** Plain publish / subscribe only; durability is the ControlPlane's responsibility.
11. **Startup order is the ingress gate.** There is no `IngressControl` on/off switch. The application starts `BullXGateway.AdapterSupervisor` only after `BullX.Runtime.Supervisor` is ready. Even when Runtime is late, durable ControlPlane buffers events, so nothing is lost.

## 4. Internal event protocol

### 4.1 Signal type list

Gateway Core defines exactly **three** stable carrier `signal.type` values:

```text
com.agentbull.x.inbound.received     # all inbound (chat / edits / recalls / reactions / actions / slash / triggers)
com.agentbull.x.delivery.succeeded   # outbound success (RFC 0003)
com.agentbull.x.delivery.failed      # outbound failure (RFC 0003)
```

Adding a new external source or event subtype does not add a new carrier type. Adapters express variation through `data.event.type` (the Gateway-owned semantic axis) and `data.event.name` (the adapter-owned concrete event name).

**Carrier type vs. semantic type.** These are different axes living in different slots:

- `signal.type` (CloudEvents envelope, top-level) — the **carrier** type. Three stable values only (`inbound.received`, `delivery.succeeded`, `delivery.failed`). Used by Bus subscription globs.
- `signal.data["event"]["type"]` — the **semantic** type of the inbound interaction. Seven values. Used by Runtime to branch on what *kind* of thing happened.
- `signal.data["event"]["name"]` — the adapter-owned **concrete event name**. Used by Runtime / skills to dispatch on platform specifics.

Subscribers should never switch on `signal.type` to distinguish `"message"` vs `"reaction"` — that's what `data.event.type` is for.

This RFC owns `com.agentbull.x.inbound.received`. The two `delivery.*` types are produced by the egress path defined in RFC 0003; the carrier name and Bus subscription pattern are introduced here so the Bus contract is complete from one document.

Bus subscription example:

```elixir
# Runtime subscribes to all inbound signals
Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.inbound.**",
  dispatch: {:pid, target: runtime_dispatcher}
)

# The handler dispatches by data.event.type:
fn signal ->
  case get_in(signal.data, ["event", "type"]) do
    "message"          -> handle_chat_message(signal)
    "message_edited"   -> handle_message_edit(signal)
    "message_recalled" -> handle_message_recall(signal)
    "reaction"         -> handle_reaction(signal)
    "action"           -> handle_card_action(signal)
    "slash_command"    -> handle_slash(signal)
    "trigger"          -> handle_webhook(signal)
  end
end

# Outbound result subscription (RFC 0003 produces these)
Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.delivery.**",
  dispatch: {:pid, target: runtime_delivery_watcher}
)
```

### 4.2 Content + event contract

**Every inbound signal's `data` is a Gateway-rendered canonical payload, not a verbatim mirror of the `BullXGateway.Inputs.*` struct the adapter submitted.**

The two required projections are:

| Field | Audience | Notes |
| --- | --- | --- |
| `content` | LLM / Agent / human-readable projection | Canonical multimodal content blocks, **required, non-empty**. If the source has no native body, the adapter or Gateway synthesizes a single `text` block. |
| `event` | Machine routing / tool calls / audit | Structured fact, **required**. Shape: `%{"type" => "<gateway semantic type>", "name" => "<adapter>.<event>", "version" => 1, "data" => %{...}}`. |

Other stable inbound fields (full shape in §4.6 / §4.7):

- `duplex` — boolean, derived from `event.type` (six chat-style types are `true`, `trigger` is `false`).
- `actor` — `%{id, display, bot}`; all three required. Runtime maps `actor.id` to any BullX-user-system identity when needed.
- `refs` — list of stable anchors `[%{kind, id, url?}]`, defaults to `[]`.
- `reply_channel` — only present when `duplex = true`: `%{adapter, channel_id, scope_id, thread_id?}`. Omitted (or `nil`) when `duplex = false`.
- Type-specific fields (§4.3).

`BullXGateway.Inputs.*` are internal Elixir structs the adapter passes to Gateway; they may use atom keys. When rendering the `%Jido.Signal{}`, Gateway must canonicalize:

1. Recursively normalize map keys from atom / mixed-key to string-key.
2. Project values that the protocol requires to be JSON-friendly into strings (e.g. `content.kind`, `Outcome.status`, `reaction.action :: :added | :removed` to `"added"` / `"removed"`).
3. Validate that the final `%Jido.Signal{}`'s `data` and `extensions` are JSON-neutral (no atoms, no `DateTime`, no structs, no functions).

Data flow:

```text
External raw payload
  -> Adapter-private parser / verifier (HMAC / JWT / timestamp window / ...)
  -> Adapter-owned typed event struct (e.g. GitHub.Events.IssueOpened, optional)
  -> Adapter produces projections:
       1. content          (adapter-chosen logic; or Gateway default for a few semantic types)
       2. event            (adapter-chosen name/version/data; semantic type implied by Input struct)
       3. refs / actor / type-specific fields
  -> One of BullXGateway.Inputs.* canonical structs (one of seven)
  -> BullX.Gateway.publish_inbound(input)
  -> Gateway pipeline: Security -> Dedupe -> Gating -> Moderation -> durable write -> Bus.publish
  -> Runtime / skill receives Signal with content + event
```

### 4.3 Event types (seven canonical structs)

Gateway defines seven canonical semantic event types under `BullXGateway.Inputs.*`. Adapters must map every external event to one of them. The classification follows generic IM semantics, not any single platform's API.

| Type | Gateway struct | `data.event.type` | duplex | Typical sources |
| --- | --- | --- | --- | --- |
| Chat new message (text + media) | `BullXGateway.Inputs.Message` | `"message"` | true | Feishu / Slack / Discord message posted |
| Message edited | `BullXGateway.Inputs.MessageEdited` | `"message_edited"` | true | Feishu `im.message.updated_v1`, Slack `message_changed`, Discord `MESSAGE_UPDATE` |
| Message recalled | `BullXGateway.Inputs.MessageRecalled` | `"message_recalled"` | true | Feishu `im.message.recalled_v1`, etc. |
| Emoji reaction add / remove | `BullXGateway.Inputs.Reaction` | `"reaction"` | true | Feishu / Slack / Discord reaction |
| Interactive component (button / form / modal submit) | `BullXGateway.Inputs.Action` | `"action"` | true | Feishu card button, Slack `view_submission`, ... |
| Slash command | `BullXGateway.Inputs.SlashCommand` | `"slash_command"` | true | `/help`, `/status`, ... |
| Non-chat event (webhook / polling / feed / tick) | `BullXGateway.Inputs.Trigger` | `"trigger"` | false | GitHub webhook, Stripe webhook, market tick |

**Deliberately not separate types:**

- **Modal submit** is not a separate type — semantically it is a form submit, a special `Action` (payload contains form values). Adapters use `event.name = "slack.view_submission"` / `"feishu.card.form_submit"` to distinguish platform subtypes; the protocol treats it as `Action`.
- **Modal close / dismiss** is not modelled — Slack-specific, weak semantics, Runtime almost never needs to respond. An adapter that insists may carry it as `Action` (`event.name = "slack.view_closed"`); not recommended.
- **Assistant thread started / context changed** (jido_chat has it) is not modelled — Slack Assistant Panel-specific integration; BullX has no use today; add when needed.
- **The message lifecycle triplet** (`Message` / `MessageEdited` / `MessageRecalled`) is intentional — most IM platforms support these natively, and editing one's own message is a daily occurrence.

### 4.4 Identity and dedupe

`(source, id)` is the primary idempotency contract.

- `source` is a stable adapter instance URI:
  - `bullx://gateway/feishu/default`
  - `bullx://gateway/github/default`
- `id` prefers the external stable event id:
  - Feishu event id;
  - GitHub delivery id (`X-GitHub-Delivery`);
  - When one external delivery is split into multiple internal signals, the adapter derives stable child ids: `<delivery_id>#0`, `<delivery_id>#1`;
  - For reactions / edits / recalls without a native id, adapters synthesize a stable id: `"#{event_type}:#{target_message_id}:#{actor_id}:#{action_time}"`.

Adapters may perform stateful normalization on raw events (re-aggregate split-and-reassembled chunks, merge album batches, drop bot self-echo). Gateway Core only requires that the final per-signal `(source, id)` pair satisfy the idempotency contract.

The `Deduper`'s ETS hot cache is a performance optimization. The authoritative source is `gateway_dedupe_seen` (UNLOGGED with a unique index). A `mark_seen` call only happens after a successful `Bus.publish`, so a Bus failure leaves no dedupe trace and the external source's retry can still make it through.

### 4.5 `Jido.Signal` envelope

```elixir
%Jido.Signal{
  specversion: "1.0.2",
  id: "evt_...",                      # external stable event id (dedupe primary key source)
  source: "bullx://gateway/feishu/default",
  type: "com.agentbull.x.inbound.received"
       | "com.agentbull.x.delivery.succeeded"
       | "com.agentbull.x.delivery.failed",
  subject: "feishu:chat_abc",         # human-readable / log display only
  time: "2026-04-21T10:00:00Z",
  datacontenttype: "application/json",
  data: %{...},                       # see §4.6
  extensions: %{
    "bullx_channel_adapter" => "feishu",          # required
    "bullx_channel_id"      => "default",         # required
    "bullx_caused_by"       => "<source inbound id>"  # optional (delivery.* often present, inbound rarely)
    # Optional policy pipeline extension keys (§6.8):
    # "bullx_security"             => %{...}
    # "bullx_flags"                => [%{stage, module, reason, description}, ...]
    # "bullx_moderation_modified"  => true
  }
}
```

Constraints:

- `type` / `source` / `id` / `subject` / `time` are strings.
- `data` and `extensions` are JSON-neutral (string keys, no atoms / `DateTime` / structs / functions).
- `subject` is for logs / UI / debugging only. **Machine logic must not parse `subject`.** Routing reads `extensions` or `data`.
- `extensions` carries only **envelope-level provenance**: the three fixed keys plus optional policy extension keys (§6.8). Business payload (`scope_id`, `thread_id`, `actor`, ...) is read from `data`, not duplicated into `extensions`.

### 4.6 Inbound payload examples (`com.agentbull.x.inbound.received`)

All inbound events share this single carrier. `data.event.type` determines the type-specific shape; `data.event.name` preserves the adapter-specific concrete event name; `data.duplex` determines whether reverse writes are possible.

**Example 1: Feishu group chat message (`event.type = "message"`)**

```elixir
%Jido.Signal{
  id: "om_abc123",
  source: "bullx://gateway/feishu/default",
  type: "com.agentbull.x.inbound.received",
  subject: "feishu:oc_xxx",
  time: "2026-04-21T10:00:00Z",
  datacontenttype: "application/json",
  data: %{
    "duplex" => true,

    # Flat scope contract (shared across all semantic types;
    # the same fields appear inside reply_channel for duplex types):
    "scope_id" => "oc_xxx",
    "thread_id" => nil,

    "content" => [
      %{"kind" => "text", "body" => %{"text" => "please summarize today's GitHub issues"}}
    ],

    "event" => %{
      "type" => "message",
      "name" => "feishu.message.posted",
      "version" => 1,
      "data" => %{
        "message_id" => "om_abc123",
        "chat_id" => "oc_xxx",
        "chat_type" => "group",
        "message_type" => "text",
        "mentions" => [],
        "reply_to_message_id" => nil
      }
    },

    "actor" => %{
      "id" => "feishu:user_xxx",
      "display" => "Boris",
      "bot" => false
    },

    "refs" => [
      %{"kind" => "feishu.message", "id" => "om_abc123"},
      %{"kind" => "feishu.chat",    "id" => "oc_xxx"}
    ],

    "reply_channel" => %{
      "adapter" => "feishu",
      "channel_id" => "default",
      "scope_id" => "oc_xxx",
      "thread_id" => nil
    }
    # Message has no extra type-specific required fields.
  },
  extensions: %{
    "bullx_channel_adapter" => "feishu",
    "bullx_channel_id"      => "default"
  }
}
```

Notes:

- `content` is the canonical content slot. If a message has images / files / audio, the adapter appends the corresponding blocks in original order (`image` / `file` / `audio`) instead of hiding them inside `event.data`.
- `content` is the preferred model / human-readable projection. There is no parallel top-level summary field.
- `event.type` is Gateway-owned; `event.name` is adapter-defined. Under one `event.type = "message"` you might see `"feishu.message.text"`, `"feishu.message.file"`, `"slack.message.shared"`, ... Gateway Core does not enumerate or validate these.
- `event.version` is for adapter-internal schema evolution; Gateway only verifies it exists and is an integer.
- `refs` gives Runtime / tools stable anchors so they need not parse text.
- `reply_channel` lets Runtime build a Delivery; required when `duplex = true`.

**Example 2: GitHub issue opened webhook (`event.type = "trigger"`)**

```elixir
%Jido.Signal{
  id: "8f7fdc1d-...",                              # GitHub delivery id
  source: "bullx://gateway/github/default",
  type: "com.agentbull.x.inbound.received",
  subject: "github:acme/api",
  time: "2026-04-21T10:00:00Z",
  datacontenttype: "application/json",
  data: %{
    "duplex" => false,

    # trigger has no reply_channel, but scope_id / thread_id are still required:
    "scope_id" => "acme/api",
    "thread_id" => nil,

    "content" => [
      %{
        "kind" => "text",
        "body" => %{
          "text" =>
            "GitHub repo acme/api has a new issue #101: Database latency spike\n" <>
            "URL: https://github.com/acme/api/issues/101\n" <>
            "by octocat"
        }
      }
    ],

    "event" => %{
      "type" => "trigger",
      "name" => "github.issue.opened",
      "version" => 1,
      "data" => %{
        "repository" => "acme/api",
        "issue_number" => 101,
        "issue_title" => "Database latency spike",
        "issue_url" => "https://github.com/acme/api/issues/101",
        "sender_login" => "octocat"
      }
    },

    "actor" => %{
      "id" => "github:octocat",
      "display" => "octocat",
      "bot" => false
    },

    "refs" => [
      %{"kind" => "github.repo",  "id" => "acme/api",
        "url" => "https://github.com/acme/api"},
      %{"kind" => "github.issue", "id" => "acme/api#101",
        "url" => "https://github.com/acme/api/issues/101"}
    ]
    # duplex = false: reply_channel omitted.
  },
  extensions: %{
    "bullx_channel_adapter" => "github",
    "bullx_channel_id"      => "default"
  }
}
```

Notes:

- Gateway does not know what a GitHub issue is; it carries `event.data` as an opaque map.
- Trigger still carries `content`. In the common webhook case that means a single synthesized `text` block; if a trigger has richer native body (comment body, attachments, chart snapshot), the adapter emits that richer content directly.
- No `reply_channel`: to respond (e.g. comment on the issue), Runtime must call the GitHub tool / action that hits the GitHub API directly. Gateway `deliver/1` does not apply.
- `refs` is the stable anchor list for tool calls; skills do not regex-parse `content` text to extract `acme/api#101`.
- `scope_id = "acme/api"` is an adapter-defined aggregation key (repo level). A Shopify adapter might use `"shop_id:order"`; a Kafka adapter might use `"topic:partition"`. Gateway does not interpret `scope_id`'s internal structure.
- When the external source has no natural actor (market tick, polling feed, system alert), the adapter must supply a synthetic actor: `%{"id" => "system:market-feed", "display" => "Market Feed", "bot" => true}`.

**Example 3: emoji reaction (`event.type = "reaction"`)**

```elixir
data: %{
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "Boris reacted thumbs-up to a message"}}
  ],
  "event" => %{
    "type" => "reaction",
    "name" => "feishu.reaction.created",
    "version" => 1,
    "data" => %{"reaction_type" => "THUMBSUP"}
  },
  "actor" => %{"id" => "feishu:user_xxx", "display" => "Boris", "bot" => false},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_target"}],

  # type-specific
  "target_external_message_id" => "om_target",
  "emoji"  => "THUMBSUP",
  "action" => "added",                                       # "added" | "removed"

  "reply_channel" => %{"adapter" => "feishu", "channel_id" => "default", "scope_id" => "oc_xxx", "thread_id" => nil}
}
```

**Example 4: message edited (`event.type = "message_edited"`)**

```elixir
data: %{
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "please summarize **all** of today's GitHub issues"}}
  ],
  "event" => %{
    "type" => "message_edited",
    "name" => "feishu.message.edited",
    "version" => 1,
    "data" => %{"message_id" => "om_abc123", "edit_count" => 2}
  },
  "actor" => %{...},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_abc123"}],

  # type-specific
  "target_external_message_id" => "om_abc123",
  "edited_at" => "2026-04-21T10:02:00Z",

  "reply_channel" => %{...}
}
```

**Example 5: message recalled (`event.type = "message_recalled"`)**

```elixir
data: %{
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "Boris recalled a message"}}
  ],
  "event" => %{
    "type" => "message_recalled",
    "name" => "feishu.message.recalled",
    "version" => 1,
    "data" => %{"message_id" => "om_abc123", "recall_time" => "..."}
  },
  "actor" => %{...},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_abc123"}],

  # type-specific
  "target_external_message_id" => "om_abc123",
  "recalled_by_actor" => %{...},                          # may equal top-level actor
  "recalled_at" => "2026-04-21T10:05:00Z",

  "reply_channel" => %{...}
}
```

**Example 6: card button click (`event.type = "action"`; same shape applies to modal submit)**

```elixir
data: %{
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "Boris submitted action: approve"}}
  ],
  "event" => %{
    "type" => "action",
    "name" => "feishu.card.action_clicked",             # or "slack.view_submission" for modal submit
    "version" => 1,
    "data" => %{"tenant_key" => "..."}                  # platform-specific kept here
  },
  "actor" => %{...},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_card"}],

  # type-specific
  "target_external_message_id" => "om_card",
  "action_id" => "approve",
  "values" => %{                                         # opaque map; button value / form values / modal submit state
    "clarify_id"   => "clr_1",
    "tool_call_id" => "tc_1",
    "choice"       => "approve"
  },

  "reply_channel" => %{...}
}
```

**Example 7: slash command (`event.type = "slash_command"`)**

```elixir
data: %{
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "/status"}}
  ],
  "event" => %{"type" => "slash_command", "name" => "feishu.command.issued", "version" => 1, "data" => %{}},
  "actor" => %{...},
  "refs"  => [...],

  # type-specific
  "command_name" => "status",
  "args" => "",

  "reply_channel" => %{...}
}
```

### 4.7 Event granularity guidelines

**The event model is not the external platform's full schema. It is the minimal stable projection that Runtime / tools / operators need.**

- Do not stuff an entire GitHub webhook payload into `event.data` — pick the fields Runtime will actually use (repo, issue number, title, URL, sender).
- Do not relay all 100+ Stripe fields — pick the ones the business cares about (amount, currency, customer_id, payment_intent_id).
- One external event may map to multiple `event.name` values (e.g. GitHub `pull_request` events split by `action` into `github.pull_request.opened` / `github.pull_request.merged`).
- Conversely, one `event.name` may aggregate multiple external events (e.g. the market adapter coalesces 1 second of ticks into one `market.tick.received`).
- `event.version` is for adapter-owned schema evolution. v1 -> v2 should preserve backward compatibility or break explicitly; the adapter's RFC owns that policy.
- **`event.type` is Gateway's; `event.name` is the adapter's.** Two layers of projection, with clean separation. Runtime can dispatch on both (coarse by `event.type`, fine by `event.name`).

A sizing rule of thumb (inspired by jido_integration's devops proof): a handler that needs `repository` / `issue_number` / `issue_title` from `event.data` already has enough to do incident routing ("page oncall"); it does not need the entire GitHub payload.

### 4.8 `subject` and `extensions`

**`subject`** is a human-readable aggregation key string:

```text
<adapter>:<scope>[:<thread>]
```

Examples: `feishu:oc_xxx`, `feishu:oc_xxx:topic_12`, `github:acme/api`.

**Machine logic must not parse `subject`.** Routing, cache keys, tool arguments must read `data` or `extensions`.

**`extensions`** carries only envelope-level provenance — the three fixed keys:

```elixir
%{
  "bullx_channel_adapter" => "feishu" | "github" | "slack" | ...,  # required
  "bullx_channel_id"      => "default",                             # required
  "bullx_caused_by"       => "<source inbound signal id>"           # optional (delivery.* often)
}
```

Optional policy pipeline extension keys (§6.8):

- `"bullx_security"` — metadata returned by `Security.verify_sender` (when the adapter chooses to populate it);
- `"bullx_flags"` — `[%{"stage", "module", "reason", "description"}, ...]`, accumulated by `Moderation`;
- `"bullx_moderation_modified"` — `true` when at least one moderator returned `:modify`.

**`scope_id` and `thread_id` are not put in `extensions`** (they live in `data`). Routing uses `signal.type`; `extensions` is provenance / audit only.

**There is no `bullx_scope_kind`** (`"dm" | "group" | "channel"`). Forcing webhook sources to pretend to be chat scopes only creates semantic pollution. `dm` / `group` / `channel` / `repo` / `feed` are adapter-internal semantics (and may live in `event.data.chat_type` for example); Gateway Core need not understand them.

Bot-self-echo filtering and bot-message identification are adapter responsibilities; the adapter drops them internally. No dedicated extension flag exists.

**Actor identity.** `actor.id` stably identifies the sender; Runtime maps it to business identity when needed.

### 4.9 Typed signal modules

The Gateway defines exactly **three** typed signal modules, each with `new/1` and `new!/1`:

- `BullXGateway.Signals.InboundReceived`
- `BullXGateway.Signals.DeliverySucceeded` (RFC 0003)
- `BullXGateway.Signals.DeliveryFailed` (RFC 0003)

`InboundReceived.new/1` contract:

```elixir
@type input ::
        BullXGateway.Inputs.Message.t()
        | BullXGateway.Inputs.MessageEdited.t()
        | BullXGateway.Inputs.MessageRecalled.t()
        | BullXGateway.Inputs.Reaction.t()
        | BullXGateway.Inputs.Action.t()
        | BullXGateway.Inputs.SlashCommand.t()
        | BullXGateway.Inputs.Trigger.t()

@spec new(input()) :: {:ok, Jido.Signal.t()} | {:error, term()}
```

#### Inbound carrier validation: carrier only

`BullXGateway.Inputs.*` may arrive at `InboundReceived.new/1` as internal atom-key structs. The first step canonicalizes; the second step validates the final signal payload.

**Validation steps** (executed in order):

1. **Top level:** `type` is exactly `"com.agentbull.x.inbound.received"`; `source`, `id`, `time` are non-empty; `specversion = "1.0.2"`.
2. **JSON projection:** `data` and `extensions` are string-key JSON-neutral maps.
3. **Extensions provenance:** `bullx_channel_adapter` and `bullx_channel_id` exist and are non-empty; optional keys are validated when present.
4. **Event projection:** `data.event` is `%{"type" => _, "name" => _, "version" => _, "data" => _}` where:
   - `data.event.type` is one of the seven allowed values.
   - `data.event.name` is a non-empty string (the value is not checked against any whitelist).
   - `data.event.version` is an integer.
   - `data.event.data` is a map (may be `%{}`, but must be a map).
   - `data.duplex` is a boolean and consistent with `event.type` (six chat types `true`, `trigger` `false`).
5. **Content projection:**
   - `data.content` is a non-empty list of `%{"kind" => kind_string, "body" => map}`.
   - `data.content[].kind` is one of the six stable kinds: `"text" | "image" | "audio" | "video" | "file" | "card"`.
   - For non-`"text"` kinds, `content.body["fallback_text"]` is a required non-empty string (the only hard contract in §5.2).
   - If an Input arrives without natural content for a semantic type that Gateway knows how to render (`reaction`, `message_recalled`, `action`, `slash_command`), the render step may synthesize one `text` block before validation. Validation still only sees the final non-empty signal payload.
6. **Stable fields:**
   - **`data.scope_id`** is required and a non-empty string. All semantic types share it; the inbound carrier surfaces it at the top of `data` (not only inside `reply_channel`).
   - **`data.thread_id`** is a required key whose value may be `nil` or a non-empty string. All semantic types must include the key; the value is adapter-decided.
   - `data.actor` is exactly `%{"id" => non_empty_string, "display" => non_empty_string, "bot" => bool}`. The non-empty `display` is a hard contract because it is the only actor field surfaced to LLM / operator-facing text (default templates, rendered `content`).
   - `data.refs` is a list of `%{"kind" => _, "id" => _, "url" => _ | nil}`; defaults to `[]`.
   - When `duplex = true`, `data.reply_channel` is required: `%{"adapter" => _, "channel_id" => _, "scope_id" => _, "thread_id" => _ | nil}`. Its `scope_id` / `thread_id` should match the top-level `data.scope_id` / `data.thread_id` (redundant but lets Runtime build a Delivery without crossing fields).
   - When `duplex = false`, `data.reply_channel` is omitted or `nil`; the top-level `data.scope_id` / `data.thread_id` are still required.
7. **Type-specific:** see §4.3 struct fields. For example, `Reaction` requires `target_external_message_id`, `emoji`, `action ∈ {"added", "removed"}`; `MessageEdited` requires `target_external_message_id`; `Action` requires `target_external_message_id` and `action_id`; etc.

**Not validated:**

- The specific value of `event.name` (no allowed-value whitelist).
- Field-level shape of `event.data` (Gateway does not know what a GitHub issue contains).
- `content.body` beyond the §5.2 minimum carrier contract (e.g. card payload schema).
- `refs[].kind` whitelist.
- The textual format of a synthesized `text` content block.

This is exactly what **"Gateway validates the carrier, not the event"** means in practice.

#### Usage constraint

**Adapters and Runtime must not bypass the typed signal module by constructing `%Jido.Signal{}` and calling `Bus.publish/2` directly for inbound.** The inbound path must go through `BullX.Gateway.publish_inbound/1`, which internally calls `InboundReceived.new/1`. If rendering or validation fails, `publish_inbound/1` returns `{:error, reason}` and the signal does not enter the Bus.

`new!/1` is the fast path for already-clean inputs (raises on failure).

The two outbound result signal modules (`DeliverySucceeded`, `DeliveryFailed`) are defined in RFC 0003.

## 5. Content body shape (shared)

This RFC owns the authoritative definition of `BullXGateway.Delivery.Content`'s body shape because the same shape is used by inbound `data["content"][]` blocks. RFC 0003 references this section without redefining it.

```elixir
defmodule BullXGateway.Delivery.Content do
  @type kind :: :text | :image | :audio | :video | :file | :card
  @type t :: %__MODULE__{kind: kind(), body: map()}
end
```

Once a `Content.kind` enters the Gateway protocol it must satisfy a minimum `body` contract. The contract applies both to outbound `BullXGateway.Delivery.Content` and to inbound `data["content"][]` canonical blocks (inbound blocks project `kind` to a string).

**Minimum body shape** (every non-`:text` kind must include `fallback_text` as a non-empty string — this is the **only hard contract** Gateway enforces, it underwrites every degradation path):

- `:text` — `%{"text" => String.t()}`.
- `:image` — `%{"url" => String.t(), "fallback_text" => String.t(), "media_type" => String.t() | nil, "alt_text" => String.t() | nil, "width" => non_neg_integer() | nil, "height" => non_neg_integer() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:audio` — `%{"url" => String.t(), "fallback_text" => String.t(), "media_type" => String.t() | nil, "duration" => non_neg_integer() | nil, "transcript" => String.t() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:video` — `%{"url" => String.t(), "fallback_text" => String.t(), "media_type" => String.t() | nil, "duration" => non_neg_integer() | nil, "width" => non_neg_integer() | nil, "height" => non_neg_integer() | nil, "thumbnail_url" => String.t() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:file` — `%{"url" => String.t(), "fallback_text" => String.t(), "filename" => String.t() | nil, "media_type" => String.t() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:card` — `%{"format" => String.t(), "payload" => map(), "fallback_text" => String.t()}`.

The shape is "**`kind` enum + `body` is a map + non-text kinds have `fallback_text`**" plus an agreed-on shape for the rest (consumers that cannot read a field fall back to `fallback_text`). Additional fields are allowed.

**Single `url` URI field.** The previous design separated `url` (HTTP) from `data` (data URI). This RFC merges them into a single `url`: the string itself is a URI, supporting any scheme — `https://cdn.example.com/xxx.png` (external) or `data:image/png;base64,iVBORw0KGgo...` (inline data URI). Both are URIs, splitting them serves no purpose. Consumers dispatch by URI scheme. The field is **required, non-empty**. The `path` option is removed: Gateway does not abstract local-file access; an adapter holding local bytes must upload to a URL or encode as a data URI before populating `url`.

**No max-size cap.** Sizing is the adapter author's responsibility. Large files must be uploaded to an external store and referenced by an HTTP(S) URL; multi-megabyte data URIs in a Signal are not allowed. The reasoning: a cap inside Gateway would either be too low for some legitimate adapter (forcing a workaround) or too high to provide real protection. Adapters know their platform's payload limits and own the decision.

This is only the minimum delivery contract; it is not a unified media cache. Adapters remain responsible for magic-byte detection, upload / download, platform limits, chunking, native fallback, and platform-private card schemas.

## 6. Channel and adapter

### 6.1 Channel identity and registration

**A channel is identified by `{adapter_atom, channel_id_string}`.** `channel_id` is the per-binding string that distinguishes different logical channels sharing the same adapter module. The concept exists so a single adapter type can serve multiple concrete external sources in the same node — e.g. one `:github` adapter module bound once per repository, one `:slack` or `:feishu` adapter bound once per external workspace — each registered under a distinct `channel_id` with its own config, credentials, and retry policy.

Examples: `{:feishu, "default"}`, `{:feishu, "acme_workspace"}`, `{:github, "acme/api"}`, `{:github, "acme/web"}`.

Adapter modules do not declare channels statically via `channel/0`; the `channel_id` is per-instance configuration, not a module-level static attribute. Runtime code should normally start a channel through `BullXGateway.AdapterSupervisor.start_channel/3`, which owns the adapter subtree lifecycle, registers the channel, and stores the channel-supervisor pid as `config.anchor_pid` for `ScopeWorker` monitoring:

```elixir
BullXGateway.AdapterSupervisor.start_channel(
  {:feishu, "default"},
  BullXGateway.Adapters.Feishu,
  config
)
```

`BullXGateway.AdapterRegistry.register/3` remains a narrow registry API for tests and manually supervised adapters. It does not start adapter children and does not synthesize `anchor_pid`.

`config` shape (Gateway-shared metadata + adapter-specific fields):

```elixir
%{
  # shared metadata (read by Gateway)
  dedupe_ttl_ms: 5 * 60 * 1000,              # per-adapter dedupe TTL
  retry_policy: %{                            # outbound retry policy (RFC 0003)
    max_attempts: 5,
    base_backoff_ms: 1000,
    max_backoff_ms: 30_000
  },

  # adapter-specific (read by the adapter)
  app_id: "cli_xxx",
  app_secret: "xxx",                          # credential management is in BullX.Config (RFC 0001)
  ...
}
```

### 6.2 The `BullXGateway.Adapter` behaviour

Adapters are registered and started under the supervision tree owned by this RFC, so the **full** behaviour definition lives here. Egress call-contract details (when ScopeWorker calls `deliver/2` / `stream/3`, retry semantics, etc.) are spelled out in RFC 0003.

```elixir
defmodule BullXGateway.Adapter do
  @type context :: %{
          required(:channel) => BullX.Delivery.channel(),
          required(:config) => map(),
          required(:telemetry) => map(),
          optional(atom()) => term()
        }

  # op capabilities — correspond to BullX.Delivery.op(); used by Gateway deliver/1 pre-check
  @type op_capability :: :send | :edit | :stream
  # metadata capabilities — adapter self-description for UI / Runtime reference; not used in pre-check
  @type metadata_capability :: :reactions | :cards | :threads | atom()
  @type capability :: op_capability() | metadata_capability()
  @type localized_url_map :: %{String.t() => String.t()}
  @type connectivity_status :: :ok
  @type connectivity_result :: %{
          required(:status) => connectivity_status(),
          optional(:adapter) => atom(),
          optional(:channel_id) => String.t(),
          optional(:identity) => map(),
          optional(:capabilities) => [capability()],
          optional(:details) => map()
        }

  @callback adapter_id() :: atom()
  @callback config_docs() :: localized_url_map()

  @callback child_specs(channel :: BullX.Delivery.channel(), config :: map()) ::
              [Supervisor.child_spec()]

  @callback connectivity_check(channel :: BullX.Delivery.channel(), config :: map()) ::
              {:ok, connectivity_result()} | {:error, map()}

  @callback deliver(BullX.Delivery.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

  @callback stream(BullX.Delivery.t(), Enumerable.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

  # capabilities/0 is required: Gateway deliver/1 pre-check depends on it
  @callback capabilities() :: [capability()]

  @optional_callbacks [
    child_specs: 2,
    deliver: 2,
    stream: 3
  ]
end
```

Callback contract:

- `adapter_id/0` **required**: module's static identity (atom).
- `config_docs/0` **required**: localized operator documentation URLs keyed by BCP 47-ish locale strings. Setup/control-plane UI selects the current locale key and falls back to `"en-US"` when the adapter does not provide a locale-specific URL.
- `child_specs/2` **optional**: the adapter starts its own listener / WebSocket / polling / webhook server / signature verifier / rate limiter / token manager. Gateway hangs them under `AdapterSupervisor`.
- `connectivity_check/2` **required**: validates the channel config enough to prove credentials and endpoint reachability before setup/control-plane code persists an enabled adapter. It may perform bounded external API calls, but it must not start listener children, register the channel, publish inbound signals, enqueue deliveries, consume activation codes, or mutate BullX account/config state. Returned maps must be JSON-neutral and secret-free.
- `context` contains at least `%{channel, config, telemetry}`; additional fields are allowed (e.g. an anchor pid for the adapter subtree, so ScopeWorker can `Process.monitor` it).
- `deliver/2` **optional**: handles `:send` and `:edit` ops. The adapter must declare the matching op in `capabilities/0`.
- `stream/3` **optional**: handles `:stream`, consuming an `Enumerable.t()`. The adapter must declare `:stream` in `capabilities/0`.
- `capabilities/0` **required**: part of the adapter contract. Gateway `deliver/1` pre-check (RFC 0003) depends on it. Pure inbound adapters (e.g. GitHub webhook) return `[]`.

Connectivity error maps follow the same adapter-owned, JSON-neutral convention as delivery errors:

```elixir
%{
  "kind" => "auth" | "config" | "network" | "rate_limit" | "unknown",
  "message" => "safe operator-facing summary",
  "details" => %{}
}
```

Adapters should use `"auth"` for rejected credentials, `"config"` for locally invalid required fields, `"network"` for DNS/TLS/timeout/reachability failures, and `"rate_limit"` when the external platform refuses the check temporarily. Secrets, tokens, OAuth codes, raw response bodies, and decrypted webhook payloads must not appear in `message` or `details`.

**Two capability semantics, kept separate:**

1. **Op capabilities** (`:send | :edit | :stream`) correspond one-to-one with `BullX.Delivery.op()`. Gateway `deliver/1` pre-check looks at exactly these three: when the adapter has not declared the requested op, the pre-check publishes `delivery.failed{error.kind = "unsupported"}` and writes a DLQ entry (RFC 0003).
2. **Metadata capabilities** (`:reactions | :cards | :threads | ...`) are adapter self-descriptions intended for UI / Runtime / skill **reference**. **Gateway does not use them in pre-check.** For example, when Runtime sends `Delivery{op: :send, content: %{kind: :card, ...}}` to an adapter that declared only `[:send]` (and not `:cards`), Gateway still routes the delivery to `ScopeWorker` and `deliver/2`. The adapter degrades by rendering `content.body["fallback_text"]` as plain text (§6.7). **A `:send` is rejected only when `:send` itself is missing from capabilities, not when `:cards` is missing.**

Examples:

```elixir
def capabilities, do: [:send, :edit, :stream, :reactions, :cards]

def deliver(%Delivery{op: :send} = d, ctx), do: ...
def deliver(%Delivery{op: :edit} = d, ctx), do: ...

def stream(%Delivery{op: :stream} = d, enumerable, ctx), do: ...
```

Adapter that doesn't support a particular op (e.g. Discord-only adapter without `:stream`):

```elixir
def capabilities, do: [:send, :edit]            # :stream omitted
def deliver(%Delivery{op: :send} = d, ctx), do: ...
def deliver(%Delivery{op: :edit} = d, ctx), do: ...
# stream/3 not implemented; Gateway pre-check rejects op: :stream deliveries
```

Pure inbound adapter:

```elixir
def capabilities, do: []                        # no outbound capability
# deliver/2 / stream/3 not implemented; any Delivery fails pre-check
```

A missing callback combined with a missing capability declaration means **the adapter does not support the corresponding op**. Gateway pre-check uses `capabilities/0` and never relies on `function_exported?` to decide.

### 6.2.1 Setup/control-plane adapter configuration

The runtime adapter list still resolves to the tuple shape used everywhere else in Gateway:

```elixir
[
  {{:feishu, "default"}, BullXFeishu.Adapter, %{...}},
  {{:github, "acme/api"}, BullXGithub.Adapter, %{...}}
]
```

Setup and future control-plane screens do not write this tuple syntax directly. They submit a JSON-neutral adapter array to Gateway's configuration boundary, and Gateway owns converting it into the runtime tuple list before writing `bullx.gateway.adapters` to `app_configs`.

Persisted JSON shape:

```json
[
  {
    "id": "feishu:ops-main",
    "enabled": true,
    "adapter": "feishu",
    "channel_id": "ops-main",
    "domain": "feishu",
    "authn": {
      "external_org_members": {
        "enabled": true,
        "tenant_key": "tenant_xxx"
      }
    },
    "credentials": {
      "app_id": "cli_xxx",
      "app_secret": "xxx"
    },
    "advanced": {
      "dedupe_ttl_ms": 300000,
      "message_context_ttl_ms": 2592000000,
      "card_action_dedupe_ttl_ms": 900000,
      "inline_media_max_bytes": 524288,
      "stream_update_interval_ms": 100,
      "state_max_age_seconds": 600
    }
  }
]
```

Rules:

- `adapters` is an ordered array. Order is stable for human review and deterministic runtime conversion; it is not a delivery priority.
- Each enabled entry must have a unique `{adapter, channel_id}` pair after normalization. `adapter` is a known catalog key, not arbitrary user-supplied module text. Gateway maps known keys to modules, e.g. `"feishu"` -> `BullXFeishu.Adapter`.
- Disabled entries may remain in the array as drafts. Disabled entries are not converted to runtime specs, are not started under `AdapterSupervisor`, and do not need a successful connectivity check.
- `config` is an adapter-owned object. Gateway validates only shared fields (`enabled`, `adapter`, `channel_id`) and delegates adapter-specific validation to the adapter's config normalizer and `connectivity_check/2`.
- Nested objects and arrays are first-class. Setup must preserve them structurally; it must not flatten adapter-specific maps such as `credentials`, `advanced`, retry policy, or future adapter-owned objects into dotted string keys.
- Secrets submitted through Setup are write-only from the UI perspective. A later edit view may show "configured" metadata, but it must not return the plaintext secret from the database.
- The database row key is `bullx.gateway.adapters`, matching `config :bullx, :gateway, adapters`. The row value is an encoded representation that `BullX.Config.Gateway.AdapterList` can cast into the runtime list. Invalid database values fall through according to RFC 0001 rather than crashing boot.

Before persistence, the control-plane flow is:

```text
1. Browser submits the adapter array draft.
2. BullXWeb checks the setup gate/session and calls Gateway config validation.
3. Gateway normalizes shared shape and adapter-specific config.
4. Gateway calls adapter.connectivity_check({adapter, channel_id}, config) for every enabled entry.
5. If any enabled entry fails, BullXWeb returns field/global errors and does not write `app_configs`.
6. If all enabled entries pass, BullX.Config.put("bullx.gateway.adapters", encoded_runtime_value) writes the row and refreshes ETS.
7. Adapter startup/reload is a separate operation; the connectivity check itself does not start children.
```

The successful check is tied to a fingerprint of the submitted enabled entry. If the operator changes any adapter entry field, including `adapter`, `channel_id`, or `enabled`, the previous success is stale and Setup must require another connectivity check before save. The browser may display this state, but it is not trusted: the save endpoint must verify a server-signed connectivity token or a server-side setup-session record for the recomputed fingerprint.

### 6.3 `BullXGateway.Inputs.*` — the seven canonical input structs

An adapter listener constructs one of seven canonical structs and hands it to Gateway; Gateway renders the `%Jido.Signal{}` and publishes.

**Shared fields (every semantic type):**

```elixir
%{
  id: String.t(),                       # external stable event id; becomes signal.id
  source: String.t(),                   # adapter instance URI
  subject: String.t() | nil,            # optional; Gateway derives "<adapter>:<scope>[:<thread>]" if omitted
  time: DateTime.t() | nil,             # optional; Gateway writes utc_now if omitted
  channel: BullX.Delivery.channel(),    # {adapter, channel_id}
  scope_id: String.t(),
  thread_id: String.t() | nil,
  actor: %{
    id: String.t(),                     # required, platform identity
    display: String.t(),
    bot: boolean()
  },
  content: [content_block] | nil,
  refs: [%{kind: String.t(), id: String.t(), url: String.t() | nil}],
  event: %{
    name: String.t(),
    version: non_neg_integer(),
    data: map()
  },
  reply_channel: %{                     # only for duplex = true types
    adapter: atom(),
    channel_id: String.t(),
    scope_id: String.t(),
    thread_id: String.t() | nil
  } | nil
}
```

`event.type` is implied by the concrete `BullXGateway.Inputs.*` struct. The adapter supplies only the adapter-owned `event.name` / `event.version` / `event.data`; Gateway renders the semantic `event.type` into the final signal.

**Type-specific fields:**

- `BullXGateway.Inputs.Message`: `content :: [content_block]` is required; `reply_to_external_id :: String.t() | nil`; `mentions :: [%{actor_id, offset_range}] | nil`.
- `BullXGateway.Inputs.MessageEdited`: `target_external_message_id :: String.t()`; `content :: [content_block]` (the updated body) is required; `edited_at :: DateTime.t() | nil`.
- `BullXGateway.Inputs.MessageRecalled`: `target_external_message_id :: String.t()`; `recalled_by_actor :: actor() | nil` (may differ from top-level actor); `recalled_at :: DateTime.t() | nil`. `content` may be supplied by the adapter or rendered by Gateway as a single `text` block (`"<recaller.display> recalled a message"`, where `recaller = recalled_by_actor || actor`).
- `BullXGateway.Inputs.Reaction`: `target_external_message_id :: String.t()`; `emoji :: String.t()`; `action :: :added | :removed`. `content` may be supplied by the adapter or template-defaulted by Gateway when omitted.
- `BullXGateway.Inputs.Action`: `target_external_message_id :: String.t()`, `action_id :: String.t()`, `values :: map()` (opaque — button value, form values, modal submit payload, ...).
- `BullXGateway.Inputs.SlashCommand`: `command_name :: String.t()`, `args :: String.t()`, `reply_to_external_id :: String.t() | nil`. `content` may be supplied by the adapter or rendered by Gateway as one `text` block from `"/#{command_name} #{args}"`.
- `BullXGateway.Inputs.Trigger`: `content :: [content_block]` is required in practice. Most trigger adapters emit one `text` block, but richer multimodal content is allowed. Note that `reply_channel` does not exist (`duplex = false`).

Usage:

```elixir
input = %BullXGateway.Inputs.Trigger{
  id: github_delivery_id,
  source: "bullx://gateway/github/default",
  content: GitHub.Events.IssueOpened.to_content(event),
  event: %{
    name: "github.issue.opened",
    version: 1,
    data: %{repository: event.repository, issue_number: event.issue_number}
  },
  actor: %{
    id: "github:#{event.sender_login}",
    display: event.sender_login,
    bot: false
  },
  refs: GitHub.Events.IssueOpened.to_refs(event),
  channel: {:github, "default"},
  scope_id: event.repository,
  thread_id: nil
}

case BullX.Gateway.publish_inbound(input) do
  {:ok, :published} -> ack_external_source()
  {:ok, :duplicate} -> ack_external_source()
  {:error, reason}  -> retry_via_external_source(reason)
end
```

### 6.4 Event model — adapter-internal struct freedom

The Gateway protocol layer is the seven canonical semantic-type structs (§6.3); whether an adapter additionally defines a per-platform-event struct is purely an adapter engineering decision. Gateway **does not care, does not assume, does not recommend, does not forbid**.

For example, the Feishu adapter might organize internally as:

```text
BullXGateway.Adapters.Feishu.Events.MessagePosted
BullXGateway.Adapters.Feishu.Events.CardActionClicked
BullXGateway.Adapters.Feishu.Events.ReactionCreated
BullXGateway.Adapters.Feishu.Events.MessageEdited
BullXGateway.Adapters.Feishu.Events.MessageRecalled
...
```

Each adapter-internal struct typically exposes:

- `from_raw/1 :: raw_payload -> {:ok, t()} | {:error, reason}`;
- `to_canonical/1 :: t() -> BullXGateway.Inputs.*` — maps the platform event into one of Gateway's seven canonical structs;
- Or the adapter may forgo internal structs entirely and use helper functions — equally valid.

**The Gateway contract only cares which `BullXGateway.Inputs.*` canonical struct is finally submitted.** Adapter-internal code organization does not enter the Gateway contract.

**Guiding principles:**

- The canonical mapping carries only the fields Runtime / tools will use; do not relay 100+ platform fields.
- `content` is the model-facing / operator-facing projection. When a semantic type has no native body (reaction / recall / slash command / some actions), Gateway may default-render one `text` block.
- `event.data` is a structured projection for machine routing / tool calls; values stay JSON-friendly, keys may be atoms inside the adapter and Gateway canonicalizes at the boundary.
- `refs` exposes stable anchors so Runtime / skills do not parse `content` text to rediscover structure.

### 6.5 `publish_inbound/1` API and pipeline

```elixir
@spec BullX.Gateway.publish_inbound(
        BullXGateway.Inputs.Message.t()
        | BullXGateway.Inputs.MessageEdited.t()
        | BullXGateway.Inputs.MessageRecalled.t()
        | BullXGateway.Inputs.Reaction.t()
        | BullXGateway.Inputs.Action.t()
        | BullXGateway.Inputs.SlashCommand.t()
        | BullXGateway.Inputs.Trigger.t(),
        keyword()
      ) ::
        {:ok, :published}
        | {:ok, :duplicate}
        | {:error, {:invalid_input, term()}}
        | {:error, {:security_denied, :verify, atom(), String.t()}}
        | {:error, {:policy_denied, :gating | :moderation, atom(), String.t()}}
        | {:error, {:moderation_invalid_return, module(), term()}}
        | {:error, {:bus_publish_failed, term()}}
        | {:error, {:store_unavailable, term()}}
```

**Call flow** (the Security / Gating / Moderation hooks are defined in §6.8):

```text
External transport event
  -> adapter-private parser / verifier (HMAC / JWT / timestamp window / ...)
  -> adapter builds typed event struct (optional) + maps to canonical struct
  -> BullX.Gateway.publish_inbound(input, opts)
     1. InboundReceived.new/1 canonicalize + validate (§4.9)
     2. Security.verify_sender (§6.8) — failure returns {:error, {:security_denied, :verify, _, _}}, no mark_seen
     3. Deduper.seen?(source, id) — ETS hot path + dedupe_seen backing; hit returns {:ok, :duplicate}
     4. Construct SignalContext (§6.8)
     5. Gating.run_checks — failure returns {:error, {:policy_denied, :gating, _, _}}
     6. Moderation.apply_moderators — :reject returns {:error, {:policy_denied, :moderation, _, _}};
        :modify replaces signal (re-runs §4.9 validation); :flag accumulates into extensions.bullx_flags
     7. Jido.Signal.Bus.publish(BullXGateway.SignalBus, [signal])
        — failure returns {:error, {:bus_publish_failed, _}}; external source retries
     8. Deduper.mark_seen(source, id, ttl_ms) — writes ETS + gateway_dedupe_seen
     9. Return {:ok, :published}
  -> adapter ack the external event according to the return (webhook 2xx / websocket ack / polling commit)
```

**Adapter ack contract:**

```elixir
case BullX.Gateway.publish_inbound(input) do
  {:ok, :published} -> ack              # published to Bus AND marked seen
  {:ok, :duplicate} -> ack              # already recorded, adapter MUST ack
  {:error, _}       -> do_not_ack       # not published, external source MUST retry
end
```

**Why ack-after-publish is sufficient.** The external source's own retry (webhook redelivery, websocket reconnect replay, polling commit-on-ack) is the single recovery loop for a publish gap. Because `mark_seen` only writes on a successful `Bus.publish`, a Bus failure leaves no dedupe trace and the source's retry proceeds normally. `signal.id` is stable (derived from the external event id), so a subscriber that sees the same signal twice because of retry is idempotent on `signal.id`. There is no in-flight per-event row to reap and no background replay sweep.

**Rejection-path persistence rules.** Security / Gating / Moderation failures are reported only via `:telemetry` (§6.8) and the synchronous return value. Nothing is written to PostgreSQL for rejected inbound events.

### 6.6 `Webhook.RawBodyReader`

**Webhook is just a transport shell, not a business abstraction.** GitHub, Shopify, Stripe, DingTalk, Feishu have entirely different signature algorithms, payload structures, retry semantics, and event rendering. Gateway Core does not abstract these differences and does not define `BullXGateway.WebhookRequest` (raw body / headers / query / remote IP are adapter-internal concerns).

Each webhook source is its own adapter and **self-hosts its listener**: the listener is part of the adapter's `child_specs/2` subtree. Adapters may share library-level utilities (e.g. an HMAC verification helper), but those do not become Gateway Core protocol.

**However**, Gateway provides one strictly-scoped helper:

```elixir
BullXGateway.Webhook.RawBodyReader     # Plug body_reader implementation
# Usage: plug Plug.Parsers, body_reader: {BullXGateway.Webhook.RawBodyReader, :read_body, []}
```

It solves the mechanical problem that "Plug consumes the body by default, leaving downstream verifiers without the original bytes". It contains **no verification logic**. Adapters use it to obtain the raw body, then perform HMAC / JWT / any-algorithm verification themselves.

**`RawBodyReader` and the "Gateway Core does not depend on `Plug.Conn`" boundary.**

- **Gateway Core** (`BullXGateway` / `ControlPlane` / `Dispatcher` / `Adapter` behaviour / `Inputs.*` / signal modules / Security / Gating / Moderation behaviours) **does not depend on `Plug.Conn`** — the core runtime path contains no Plug types.
- **`BullXGateway.Webhook.RawBodyReader`** is an **optional adapter-support helper** placed under the `BullXGateway.Webhook` subnamespace; adapters `use` / `import` it inside their own webhook listeners on demand.
- **Compile-time dependency.** `plug` is declared as an **optional dependency** in `mix.exs` (`{:plug, "~> 1.14", optional: true}`). An adapter that uses `RawBodyReader` (or a host app like `BullXWeb`) declares `:plug` non-optional itself; environments without webhook adapters do not pull Plug into the compile closure.
- **Applicable scope.** Useful only for HTTP-webhook adapters (GitHub / Shopify / Stripe listeners). Long-polling / WebSocket / queue-consumer adapters do not need this helper.
- If a project does not want the Gateway app to carry any Plug optional dependency, `RawBodyReader` may be moved into `BullXWeb` or into a separate `bullx_gateway_webhook` package. This RFC keeps it under the Gateway subnamespace by default because the implementation is tiny (a few dozen lines).

**`RawBodyReader` (transport layer) vs. `Security.verify_sender` (platform layer).**

- `RawBodyReader` + adapter signature verification is a **transport-layer** check: did the external source actually send these bytes?
- `Security.verify_sender` is a **platform / business trust decision**: is this verified sender still allowed to enter?

The two coexist; neither overlaps nor replaces the other.

### 6.7 Degradation principles

Degradation is the adapter's responsibility. Gateway only insists on two hard boundaries:

1. **Gateway does not invent business fallback commands.** Runtime that wants to send a card must supply `fallback_text` (§5.2 hard contract); an adapter that does not support cards sends `fallback_text` and makes no business decisions.
2. **Degradation must be visible.** `Outcome.status = :degraded` and `warnings` records the reason (e.g. `"card_fallback_to_text"`).

The egress application of this rule is detailed in RFC 0003.

### 6.8 Policy pipeline

Gateway introduces **three pluggable pipeline hooks** — `Gating`, `Moderation`, `Security` — modelled after `jido_messaging`. **All defaults are empty.** Gateway itself ships no policy; the application wires modules into config.

**Guiding principle:** Gateway owns the carriage and the pipeline; the application owns the policy.

This RFC owns the unified pipeline definition because the inbound flow defines `Security.verify_sender`, the moderation behaviours, and the gating behaviour. The egress side reuses `Security.sanitize_outbound` (RFC 0003 references this section).

#### 6.8.1 Behaviour definitions

**`BullXGateway.Gating`:**

```elixir
defmodule BullXGateway.Gating do
  alias BullXGateway.SignalContext

  @type reason :: atom()
  @type description :: String.t()
  @type result :: :allow | {:deny, reason(), description()}

  @callback check(ctx :: SignalContext.t(), opts :: keyword()) :: result()
end
```

**`BullXGateway.Moderation`:**

```elixir
defmodule BullXGateway.Moderation do
  @type reason :: atom()
  @type description :: String.t()
  @type result ::
          :allow
          | {:reject, reason(), description()}
          | {:flag, reason(), description()}
          | {:modify, Jido.Signal.t()}

  @callback moderate(signal :: Jido.Signal.t(), opts :: keyword()) :: result()
end
```

A moderator receives the **already-rendered `%Jido.Signal{}`** (not a `BullXGateway.Inputs.*` struct). When it returns `:modify`, it must return a JSON-neutral signal that satisfies the §4.9 validation. Gateway re-runs the §4.9 validation on the modified signal; failure yields `{:error, {:moderation_invalid_return, module, detail}}`.

**`BullXGateway.Security`:**

```elixir
defmodule BullXGateway.Security do
  @type stage :: :verify | :sanitize
  @type input ::
          BullXGateway.Inputs.Message.t()
          | BullXGateway.Inputs.MessageEdited.t()
          | BullXGateway.Inputs.MessageRecalled.t()
          | BullXGateway.Inputs.Reaction.t()
          | BullXGateway.Inputs.Action.t()
          | BullXGateway.Inputs.SlashCommand.t()
          | BullXGateway.Inputs.Trigger.t()

  @callback verify_sender(
              channel :: {atom(), String.t()},
              input :: input(),
              opts :: keyword()
            ) :: :ok | {:ok, map()} | {:deny, atom(), String.t()} | {:error, term()}

  @callback sanitize_outbound(
              channel :: {atom(), String.t()},
              delivery :: BullX.Delivery.t(),
              opts :: keyword()
            ) :: {:ok, BullX.Delivery.t()} | {:ok, BullX.Delivery.t(), map()} | {:error, term()}
end
```

The shape borrows from `jido_messaging` but is BullX-specific: inputs are `BullXGateway.Inputs.*` canonical structs and `BullXGateway.Delivery`, not raw bodies or `incoming_message` types — Gateway is explicit about not touching raw bodies (§6.6).

**There is no `OutboundModeration` behaviour.** Outbound policy uses the single `Security.sanitize_outbound` hook (string truncation, URL stripping, emoji limits, etc.). Heavier content policy (tone, PII strip) belongs to the Runtime generation layer — applied where the LLM context is available.

**Rate limiting and PII redaction do not get dedicated behaviours.**

- Inbound rate limiting -> write a `Gating` module that returns `{:deny, :rate_limited, _}`.
- PII redaction -> write a `Moderation` module that returns `{:modify, redacted_signal}`.

#### 6.8.2 `BullXGateway.SignalContext`

The Gating context is derived from the rendered signal; gaters do not need to re-parse it.

```elixir
defmodule BullXGateway.SignalContext do
  @type t :: %__MODULE__{
    signal_type: String.t(),              # always "com.agentbull.x.inbound.received"
    event_type: atom(),                   # :message | :message_edited | :message_recalled |
                                          # :reaction | :action | :slash_command | :trigger
    event_name: String.t(),
    event_version: integer(),
    event_data: map(),                    # adapter-owned structured projection
    channel: {atom(), String.t()},
    scope_id: String.t(),
    thread_id: String.t() | nil,
    actor: %{id: String.t(), display: String.t(), bot: boolean()},
    duplex: boolean(),
    content: [map()],
    refs: [map()],
    signal: Jido.Signal.t()               # escape hatch
  }
end
```

This corresponds to jido_messaging's `MsgContext` but does not port `was_mentioned` / `agent_mentions` / `chat_type` / `command` — those are chat-domain semantics that the Gateway carrier layer does not recognise. Application code that needs those fields reads them off `event_data` (the adapter's concrete payload).

**`event_type` is Gateway's; `event_name` is the adapter's** — together they give gaters / moderators two granularities for dispatch. `event_data` is surfaced directly on the context (rather than forcing gaters through `ctx.signal.data["event"]["data"]`) so the four-field group stays flat and symmetric.

#### 6.8.3 Pipeline ordering

**Inbound (`publish_inbound/1`):**

```text
1. typed Signal canonicalize                 -> {:error, {:invalid_input, _}} on fail
2. Security.verify_sender                    -> {:error, {:security_denied, :verify, _, _}} on deny
                                                metadata merged into signal.extensions["bullx_security"]
3. Deduper.seen?(source, id)                 -> {:ok, :duplicate} returns here
4. Construct SignalContext
5. Gating.run_checks                         -> {:error, {:policy_denied, :gating, _, _}} on deny
6. Moderation.apply_moderators               -> {:error, {:policy_denied, :moderation, _, _}} on reject
                                                :flag accumulates into extensions["bullx_flags"]
                                                :modify replaces signal (re-validates §4.9)
7. Bus.publish(SignalBus, [signal])          -> {:error, {:bus_publish_failed, _}} on failure
8. Deduper.mark_seen(source, id, ttl_ms)
9. {:ok, :published}
```

**Why Security comes before Dedupe but Gating / Moderation come after:**

- A Security failure (unauthorized sender) must not `mark_seen`. Once the sender is authorised, the next event must enter the pipeline.
- A Gating / Moderation failure means "this one is not handled". Letting Dedupe short-circuit first is more efficient (already decided once, no need to re-decide).
- `mark_seen` runs only at step 8 (after Bus.publish succeeds). On failure, no dedupe is recorded — so the external source's retry can still get through.

**Outbound (`deliver/1`)** — the unified pipeline that RFC 0003 implements:

```text
1. Delivery shape validation
2. Channel lookup
3. Capabilities pre-check (§6.2) — only op capability (:send | :edit | :stream)
4. Security.sanitize_outbound                -> {:error, {:security_denied, :sanitize, _, _}} on deny
5. OutboundDeduper.seen?(delivery.id)        -> hit republishes the cached success outcome
                                                (only terminal success is cached)
6. ScopeWorker.enqueue(channel, scope_id, delivery)   — in-memory cast
7. ScopeWorker invokes adapter.deliver / stream
8. Outcome normalised -> delivery.** publish + OutboundDeduper.mark_success on terminal success
                      -> terminal failure writes gateway_dead_letters + publishes delivery.failed

DLQ replay path (RFC 0003): skips step 3 / step 5; rebuilds the Delivery from the dead-letter row and re-enters at step 6.
```

The egress steps run inside RFC 0003's `Dispatcher` / `ScopeWorker`. The ScopeWorker queue is in-memory; the only Store interaction on the outbound path is the DLQ write on terminal failure.

#### 6.8.4 Configuration

```elixir
config :bullx, :gateway,
  adapters: [
    {{:feishu, "default"}, BullXFeishu.Adapter, %{...}}
  ],
  gating: [
    gaters: [MyApp.TenantAllowlist, MyApp.RateLimit],
    gating_opts: [tenant_file: "priv/tenants.json"],
    gating_timeout_ms: 50
  ],
  moderation: [
    moderators: [MyApp.PiiRedact, MyApp.BotEchoFilter],
    moderation_opts: [],
    moderation_timeout_ms: 100
  ],
  security: [
    adapter: MyApp.SecurityAdapter,
    adapter_opts: [],
    verify_timeout_ms: 50,
    sanitize_timeout_ms: 50
  ],
  policy_timeout_fallback: :deny,       # :deny | :allow_with_flag
  policy_error_fallback: :deny
```

Gateway reads these settings through `BullX.Config.Gateway`, not direct `Application.get_env/2` calls. Resolution priority for a Gateway setting is: code default -> application config -> OS env -> PostgreSQL override; per-call override (`publish_inbound(input, gating: [...])`) remains highest for that one call.

`adapters` is the only Gateway setting in this RFC that is both complex and setup-writable. Application config may still supply the runtime tuple list directly. PostgreSQL setup writes use the JSON-neutral adapter array described in §6.2.1 and are decoded by `BullX.Config.Gateway.AdapterList`; subsystem code continues to consume only the runtime tuple shape returned by `BullX.Config.Gateway.adapters/0`.

Operator-facing setup terminology intentionally differs from this storage key: one persisted adapter-array element is presented as a channel, while the adapter module/catalog entry is presented as a connector. This keeps UI language aligned with what the operator is adding without changing Gateway's runtime configuration contract.

**Ordering within a stage:** list order is execution order; the first `:deny` short-circuits; moderator `:modify` cascades; `:flag` accumulates; `:reject` short-circuits.

#### 6.8.5 Error handling

Each hook runs under `Task.Supervisor.async_nolink` + `Task.yield` (falling back to `Task.shutdown(:brutal_kill)` on timeout), against the `BullXGateway.PolicyTaskSupervisor` child of `BullXGateway.CoreSupervisor`. `async_nolink` is chosen so hook work is isolated from the caller's process; `BullXGateway.PolicyRunner` normalizes raised hook errors before the task exits so the caller can apply `policy_error_fallback` without polluting logs with expected task-crash reports. Defaults: a `raise` / timeout / invalid shape resolves through `policy_error_fallback` / `policy_timeout_fallback` (both default `:deny`).

A `:modify` returning an invalid shape produces `{:error, {:moderation_invalid_return, _, _}}`; the signal does not enter the Bus.

#### 6.8.6 Telemetry

Two spans plus one terminal outbound event (seven events total) are emitted:

```text
[:bullx, :gateway, :publish_inbound, :start]
[:bullx, :gateway, :publish_inbound, :stop]
  metadata.policy_outcome ::
    :published | :duplicate | :denied_security | :denied_gating | :rejected_moderation
[:bullx, :gateway, :publish_inbound, :exception]
[:bullx, :gateway, :deliver, :start]
[:bullx, :gateway, :deliver, :stop]
  metadata.outcome :: :accepted | :duplicate | :unsupported | :invalid_delivery | :security_denied
[:bullx, :gateway, :deliver, :exception]
[:bullx, :gateway, :delivery, :finished]
  measurements.attempts :: non_neg_integer
  metadata.outcome :: :sent | :degraded | :failed
  metadata.error_kind :: String.t() | nil
```

The `:deliver` span wraps the synchronous enqueue (validate / capability / dedupe / cast ScopeWorker) and always returns quickly; its `outcome` is the enqueue verdict, not the async execution result. The async terminal result — success, degradation, or dead-letter — surfaces exactly once per delivery on `:delivery, :finished`. Per-stage policy decision events are redundant with `publish_inbound:stop.policy_outcome`; per-attempt retry events are redundant with the `attempts` distribution on `:delivery, :finished`; store transaction timing surfaces via the top-level span when the DB is slow. The span events are emitted via `:telemetry.span/3`; `:delivery, :finished` uses `:telemetry.execute/3` from `ScopeWorker`.

## 7. Runtime structure

### 7.1 Lifecycle and startup ordering

Gateway is Runtime's prerequisite infrastructure: `BullXGateway.CoreSupervisor` starts before `BullX.Runtime.Supervisor`. **There is no `IngressControl` global switch** — startup ordering is the ingress gate:

```text
BullX.Repo                                 # PostgreSQL connection; before Gateway
BullX.Config                               # see RFC 0001
BullXGateway.CoreSupervisor               # Bus + ControlPlane + Dispatcher + DLQ + Deduper
BullX.Skills.Supervisor
BullXBrain.Supervisor
BullX.Runtime.Supervisor                   # subscribes to SignalBus
BullXGateway.AdapterSupervisor            # the application attaches this child after Runtime is ready
```

**Startup order is the only ingress gate**: Runtime subscribes to the Bus before `AdapterSupervisor` is attached, so no inbound signal is published into an empty Bus. If a `Bus.publish` ever fails, `publish_inbound/1` returns an error and the adapter declines to ack — the external source retries and drives the recovery loop.

`BullXWeb.Endpoint` is the control-plane application's own startup item, not part of the Gateway contract.

### 7.2 Core supervision tree

```text
BullXGateway.CoreSupervisor
├── BullXGateway.ControlPlane            # GenServer; serializes Store reads/writes
├── BullXGateway.SignalBus               # Jido.Signal.Bus instance
├── BullXGateway.AdapterRegistry
├── BullXGateway.ScopeRegistry           # Registry (used by ScopeWorker names)               -- (RFC 0003)
├── BullXGateway.Dispatcher              # DynamicSupervisor of ScopeWorker                    -- (RFC 0003)
├── BullXGateway.Deduper                 # ETS hot cache + Store backing                       -- this RFC
├── BullXGateway.OutboundDeduper         # ETS 5-min TTL, outbound delivery.id dedupe          -- (RFC 0003)
├── BullXGateway.DLQ.ReplaySupervisor    # Registry + N ReplayWorker                           -- (RFC 0003)
├── BullXGateway.Retention               # hourly retention sweep                              -- this RFC migrates the inbound schedule
└── BullXGateway.Telemetry

BullXGateway.AdapterSupervisor           # attached by the application
├── Registry                              # channel -> per-channel supervisor pid
└── DynamicSupervisor
    └── per-channel adapter supervisors   # each wraps adapter.child_specs/2
```

Children that this RFC implements: `ControlPlane`, `SignalBus`, `AdapterRegistry`, `Deduper`, `Retention`, `Telemetry`, and `AdapterSupervisor`. `AdapterSupervisor` owns the per-channel lifecycle but does not implement any concrete adapter.

Children supervised by `CoreSupervisor` but **implemented by RFC 0003**: `Dispatcher`, `ScopeRegistry`, `OutboundDeduper`, `DLQ.ReplaySupervisor`. They appear in the tree shape so the supervisor child list is complete and stable across both RFCs; their internal modules and behaviour are defined in RFC 0003.

(There is no `IngressControl`, no `AdapterHealth`.)

### 7.3 `Jido.Signal.Bus` usage

Plain publish / subscribe; no persistent subscriptions (durability is the ControlPlane's job, not Bus checkpoints):

```elixir
Jido.Signal.Bus.publish(BullXGateway.SignalBus, [signal])

Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.inbound.**",
  dispatch: {:pid, target: runtime_dispatcher}
)

Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.delivery.**",
  dispatch: {:pid, target: runtime_delivery_watcher}
)
```

### 7.4 ControlPlane, Store, and tables

`BullXGateway.ControlPlane` is the serialized entry point for all durable writes (a GenServer). The persistence layer is abstracted by the `Store` behaviour:

```elixir
defmodule BullXGateway.ControlPlane.Store do
  # inbound dedupe (this RFC implements)
  @callback put_dedupe_seen(map) :: :ok | {:error, term}
  @callback fetch_dedupe_seen(key :: String.t()) :: {:ok, map} | :error
  @callback list_active_dedupe_seen() :: {:ok, [map]}
  @callback delete_expired_dedupe_seen() :: {:ok, non_neg_integer}

  # dead letters (RFC 0003 implements)
  @callback put_dead_letter(map) :: :ok | {:error, term}
  @callback fetch_dead_letter(dispatch_id :: String.t()) :: {:ok, map} | :error
  @callback list_dead_letters(filters :: keyword) :: {:ok, [map]}
  @callback increment_dead_letter_replay_count(dispatch_id :: String.t()) :: :ok | {:error, term}
  @callback delete_old_dead_letters(before :: DateTime.t()) :: {:ok, non_neg_integer}

  @callback transaction((module() -> result)) :: {:ok, result} | {:error, term}
end
```

The full behaviour signature lives in this RFC because the ControlPlane GenServer that hosts it is started by `CoreSupervisor` here. RFC 0003 implements the dead-letter callbacks (and the matching table).

**Sole implementation: `BullXGateway.ControlPlane.Store.Postgres`** (built on `BullX.Repo`). dev / test use the same PostgreSQL backend through the Ecto sandbox; no ETS backend is maintained, so the dev environment cannot drift from production. The behaviour abstraction exists for future pluggability and Mox-style unit tests, not for environment differentiation.

#### 7.4.1 Persistence strategy

The Gateway has exactly two tables. Both are UNLOGGED.

| Table | PostgreSQL kind | Migrated by | Reason |
| --- | --- | --- | --- |
| `gateway_dedupe_seen` | **UNLOGGED** | this RFC | Hot-cache backing; ETS rebuilds it after crash; external sources retry un-acked inbound events. |
| `gateway_dead_letters` | **UNLOGGED** | RFC 0003 | Ops-visible failure evidence; loss on unclean server crash is acceptable — Runtime + Oban re-dispatches, and a fresh terminal failure writes a new row. |

**Rationale.** The Gateway reliability boundary is "carrier-layer correctness" — *an inbound event accepted by Gateway is published to the Bus, and the policy pipeline runs before publish* — not "persist every intermediate state". Runtime + Oban holds the business-layer retry semantics; adapters hold the external-source ack semantics. In-flight envelopes (inbound pre-publish, outbound dispatches, per-attempt rows) are intentionally **not** persisted at all. UNLOGGED tables provide transactional + unique-index semantics without writing to the WAL: on an unclean server crash they are truncated, Runtime re-issues outstanding work, the external source retries un-acked inbound events.

Ecto migration style: UNLOGGED tables use `execute("CREATE UNLOGGED TABLE ...")` + `execute("DROP TABLE ...")`; if an existing table needs to switch, use `execute("ALTER TABLE ... SET UNLOGGED")`.

#### 7.4.2 `gateway_dedupe_seen` (this RFC migrates)

**`gateway_dedupe_seen`** (UNLOGGED):

| Column | Type |
| --- | --- |
| `dedupe_key` | `text` PK |
| `source` | `text` |
| `external_id` | `text` |
| `expires_at` | `timestamptz` |
| `seen_at` | `timestamptz` |

Indexes:
- PRIMARY KEY `(dedupe_key)`
- `(expires_at)`

`dedupe_key` is `sha256("#{source}|#{external_id}")`.

#### 7.4.3 Outbound table (RFC 0003 migrates; shape shown for completeness)

The single outbound table (`gateway_dead_letters`, UNLOGGED) is migrated by RFC 0003. Its full schema and index definitions live in that document. This RFC does not migrate it.

### 7.5 Inbound `Deduper`

**`BullXGateway.Deduper`** (inbound) — ETS hot cache + `gateway_dedupe_seen` durable backing:

1. Gateway boot -> `Deduper.init/1` calls `Store.list_active_dedupe_seen()` to rehydrate ETS.
2. `publish_inbound/1` step 3 queries ETS; on ETS miss it falls through to `Store.fetch_dedupe_seen/1`.
3. Step 8 (after `Bus.publish` succeeds) writes the Store first, then the ETS hot cache.
4. Sweep every minute: ETS local cleanup + `Store.delete_expired_dedupe_seen()`.
5. **TTL is per-adapter** (configured via `AdapterRegistry`'s `:dedupe_ttl_ms`): Feishu 5 minutes, GitHub 72 hours, others per their RFCs; default 24 hours.

The outbound `OutboundDeduper` is a sibling process supervised under `CoreSupervisor` but defined and implemented in RFC 0003.

### 7.6 Retention (inbound parts)

`BullXGateway.Retention` (hourly schedule, inbound responsibilities only — RFC 0003 owns the outbound rules):

- Delete `gateway_dedupe_seen WHERE expires_at < now`.

The remaining retention rules (`gateway_dead_letters` 90-day retention) belong to RFC 0003.

## 8. Inbound pipelines

### 8.1 Feishu inbound: chat message -> Runtime

```text
Feishu push / WebSocket
  -> Feishu adapter listener (decryption / signature verification / self-echo filter)
  -> Feishu.Events.MessagePosted.from_raw(payload)
  -> mapped to %BullXGateway.Inputs.Message{event.type implied by struct}
     - actor.id = "feishu:#{open_id}"
  -> BullX.Gateway.publish_inbound(input)
     - Security.verify_sender (the application can plug in a tenant allowlist)
     - Deduper (source, id) check
     - Gating / Moderation (default empty)
     - Bus.publish
     - Deduper.mark_seen (writes ETS + gateway_dedupe_seen)
  -> Runtime dispatcher subscribes to "com.agentbull.x.inbound.**"
     - Model / operator surfaces read signal.data["content"]
     - Machine routing reads signal.data["event"]["type"] + signal.data["event"]["name"]
```

### 8.2 GitHub webhook inbound -> Runtime / skill

```text
GitHub webhook HTTP POST
  -> GitHub adapter listener (uses BullXGateway.Webhook.RawBodyReader to obtain raw body
     + verifies X-Hub-Signature-256)
  -> select Events module by event header + payload:
       "issues" + action="opened" -> GitHub.Events.IssueOpened
       "pull_request" + action=*  -> GitHub.Events.PullRequestOpened / Merged / ...
  -> Events.from_raw(payload) -> typed event struct
  -> mapped to %BullXGateway.Inputs.Trigger{}
  -> BullX.Gateway.publish_inbound(input)
     -> {:ok, :published} | {:ok, :duplicate} -> respond 2xx
     -> {:error, _} -> respond 5xx so GitHub retries

Runtime / DevOps skill subscribes:
  case {signal.data["event"]["type"], signal.data["event"]["name"]} do
    {"trigger", "github.issue.opened"}        -> route_to_devops_agent(signal)
    {"trigger", "stripe.payment.succeeded"}   -> route_to_billing(signal)
    _ -> :skip
  end

LLM / operator surfaces still read signal.data["content"];
the skill takes signal.data["refs"] as tool arguments (calling the GitHub tool to comment on the issue).
```

Note: The GitHub adapter does not export `deliver/2` / `stream/3` (`capabilities/0` returns `[]` or only non-outbound capabilities). When Runtime wants to comment on a GitHub issue, it uses the GitHub tool / action that calls the GitHub REST API directly; **it does not go through Gateway `deliver/1`**. This is also why `duplex = false` and there is no `reply_channel`.

The matching outbound and stream pipelines (Runtime -> Gateway -> adapter, and the streaming card flow) are documented in RFC 0003.

## 9. Reliability (inbound parts)

The reliability story for the carrier layer:

1. **Adapter listeners are OTP-supervised.** Crashes auto-restart; a single adapter failure does not bring down the rest of Gateway.
2. **Startup order is the ingress gate.** Until Runtime is ready, `AdapterSupervisor` is not started and adapters do not consume.
3. **Ack-after-publish inbound.** `publish_inbound/1` returns success only after `Bus.publish` has succeeded AND `mark_seen` has recorded the dedupe. A Bus failure returns `{:error, {:bus_publish_failed, _}}` so the adapter declines to ack and the external source retries.
4. (RFC 0003) ScopeWorker in-memory queue per `{channel, scope_id}`.
5. (RFC 0003) DLQ + manual replay.
6. **Short-lived dedupe.** `(source, id)` inbound dedupe (ETS hot cache + `gateway_dedupe_seen` UNLOGGED backing). The outbound `delivery.id` dedupe is an RFC 0003 concern.
7. **Telemetry.** Publish-failed / adapter-crashed / pipeline-decision / retention-sweep events are emitted; the inbound-specific events listed in §6.8.6 are owned here.
8. **UNLOGGED crash semantics (inbound subset).** The one UNLOGGED table this RFC migrates (`gateway_dedupe_seen`) is truncated on unclean server crash. This is acceptable: the external source retries un-acked events, Runtime re-issues outstanding outbound work via Oban.
9. **Envelope-level framing.** Gateway does **not** provide `exactly-once`; that is a Runtime + Oban + business-persistence collaboration. Gateway provides **at-least-once with idempotent dedupe** on the inbound side and **envelope-level durable failure capture** (the DLQ) on the outbound side.

The README's references to "high availability / exactly-once" are about agent workflow runtime guarantees, not Gateway-layer guarantees. The Gateway-layer guarantee is carrier-level correctness: the pipeline runs before publish, dedupe holds across retries, and terminal outbound failures become durable DLQ rows.

## 10. Non-goals

The cross-cutting non-goals (also enumerated in §2.2 for ergonomics; collected here as a standalone section):

**Business model / lifecycle:**

- Session / turn / conversation lifecycle.
- Memory / brain / knowledge graph.
- Command alias, approval, budget, HITL, subagent, cron, agent orchestration.
- "Interrupt agent on new message" concurrency control (Runtime).
- Think-block / reasoning content filtering (Runtime).

**Business modelling structs:**

- `%Room{}` / `%Participant{}` / `%Thread{}` / `%RoomBinding{}` / `%RoutingPolicy{}` are not introduced.
- No Gateway-level multi-adapter fan-out (Runtime calls `deliver/1` N times — see RFC 0003).
- No thread lifecycle, participant registry, presence, typing.
- The `scope_kind` enum was rejected (§4.8).
- `ModalClose` / `AssistantThreadStarted` (Slack-specific) are not modelled (folded into `Action` or ignored).

**Protocol-level:**

- Generic `WebhookAdapter` / unified `WebhookRequest` / raw_body / query / remote_ip abstraction (Gateway only ships `Webhook.RawBodyReader`, §6.6).
- `event` internal schema validation beyond the carrier contract (the adapter's RFC + tests + fixtures own that).
- `failure_class` enum / retry taxonomy as a protocol contract (`error.kind` + `details.retry_after_ms` is a convention; Runtime decides retry policy — see RFC 0003).
- Bus persistent subscription / ack checkpoint (durability is the ControlPlane's job).

**Policy and reliability boundaries:**

- Audit-grade rejection persistence (rejections go to telemetry only).
- Default Gating / Moderation / Security implementations (application-supplied).
- Outbound `Moderation` behaviour (outbound policy uses the single `Security.sanitize_outbound` hook).
- Approval state machine / HITL pause-resume (Runtime).

**Acceptable losses (carrier layer):**

- Mid-stream durability (only `stream_close` outcome durable; RFC 0003).
- Exactly-once business semantics (Runtime + Oban).
- UNLOGGED tables truncated on unclean server crash (Runtime / adapter / external source re-issue).

**Distribution and media:**

- Cross-node routing / distributed bus / global consistency (single-node constraint, §3.1).
- Media long-term storage / unified media cache (per-adapter).
- Album / multi-image re-batching (adapter-internal stateful normalization).
- Text metrics / chunking algorithms / media magic-bytes verification (adapter-internal).
- Cross-adapter bot-echo defense (no jido evidence, no real-world need).

**User identity:**

- Gateway's `actor` carries only `{id, display, bot}`. Mapping `actor.id` to a BullX-user-system identity is Runtime's responsibility.
- No onboarding / registration flow (synthetic actor fallback or rejection is Runtime's call).

**Outbound-specific non-goals** (enumerated in RFC 0003): no `notify_pid` channel, no Gateway-level multi-adapter fan-out for one Delivery, no `failure_class` retry taxonomy as a protocol contract.

## 11. Acceptance criteria (inbound side)

A coding agent has completed this RFC when all of the following hold. The numbering restarts at 1 for clarity within this RFC; RFC 0003 carries its own numbering for the egress side.

### 11.1 Content + event contract

1. Any `com.agentbull.x.inbound.received` signal's `data` contains a non-empty `content` list, an `event.{type, name, version, data}` map, a `duplex` boolean, an `actor.{id, display, bot}` triple, and a `refs` list (possibly empty); when `duplex = true`, `reply_channel.{adapter, channel_id, scope_id, thread_id?}` is also present.
2. `data.event.type` is one of the seven enum values (`message` / `message_edited` / `message_recalled` / `reaction` / `action` / `slash_command` / `trigger`).
3. `data.duplex` is derived from `event.type`: six chat types `true`, `trigger` `false`.
4. `BullXGateway.Inputs.*` structs may use atom-key maps / atom kinds; the final `%Jido.Signal{}`'s `data` and `extensions` must be string-key JSON-neutral maps.
5. A `%BullXGateway.Inputs.Trigger{event: %{name: "github.issue.opened", version: 1, data: %{issue_number: 101}}}` becomes `%{"event" => %{"type" => "trigger", "name" => "github.issue.opened", "version" => 1, "data" => %{"issue_number" => 101}}}` in the published signal's `data`.
6. A source with no natural actor still supplies a synthetic actor (e.g. `%{"id" => "system:market-feed", "display" => "Market Feed", "bot" => true}`).
7. `InboundReceived.new/1` fails when:
   - `content` is missing, empty, not a list, or a block is not `%{"kind" => _, "body" => map}`;
   - `content.kind` is not in the six stable kinds;
   - non-`:text` `content.body["fallback_text"]` is missing or empty;
   - `event.type` is not in the seven values;
   - `duplex` is not boolean, or inconsistent with `event.type`;
   - `event.name` is missing or not a string; `event.version` is not an integer; `event.data` is not a map;
   - `actor.id` is empty; `actor.display` is empty;
   - `duplex = true` but `reply_channel` is missing or incomplete;
   - any type-specific required field is missing (e.g. `Reaction.target_external_message_id` / `emoji` / `action`).
8. `InboundReceived.new/1` does **not** fail when:
   - `event.name = "totally.unknown.event"`;
   - `event.data = %{}`;
   - `content.body` carries fields beyond the §5.2 minimum;
   - `refs = []`.

### 11.2 Bus routing

9. Subscribing to `"com.agentbull.x.inbound.**"` receives every inbound signal (regardless of `event.type`).
10. Subscribing to `"com.agentbull.x.delivery.**"` receives `delivery.succeeded` / `delivery.failed` (RFC 0003); inbound is not seen.
11. Gateway Core code contains no branch on a specific `event.name` value; Runtime dispatches by `data.event.type` + `data.event.name`.

### 11.3 Carrier / event layering

12. The same `inbound.received` carrier transports any `event.name` (`github.issue.opened`, `stripe.payment.succeeded`, `feishu.card.action_clicked`, ...); Gateway publishes and routes correctly.
13. Runtime dispatches based on `data.event.type` (coarse) + `data.event.name` (fine) and on `data.refs` for tool argument filling; Runtime does not have to reverse-engineer structured fields out of `content`.
14. Gateway provides a dedicated `data["content"]` slot for carrier-level text / media / card; consumers do not have to parse `event.data` to read canonical content.

### 11.4 Ingress + Dedupe

15. `BullX.Gateway.publish_inbound/1` returns are distinguishable: `{:ok, :published}`, `{:ok, :duplicate}`, `{:error, reason}`.
16. The same GitHub delivery id arriving twice -> identical `(source, id)` -> within TTL, the second call returns `{:ok, :duplicate}`; the adapter ack both `:published` and `:duplicate`.
17. The Deduper may only `mark_seen` after `Bus.publish/2` succeeds; failure leaves no dedupe record.
18. After clearing the Deduper ETS and restarting, the durable `gateway_dedupe_seen` row still hits, so the second time the same id arrives -> `{:ok, :duplicate}`.
19. A `Bus.publish` failure inside `publish_inbound/1` returns `{:error, {:bus_publish_failed, _}}`; nothing is written to the Deduper; the external source retries and a subsequent successful publish marks seen normally.
20. **Per-adapter dedupe TTL.** TTL is read from each adapter's `AdapterRegistry` config (`:dedupe_ttl_ms`) and bounds the `(source, id)` window independently per adapter. With `dedupe_ttl_ms: 300_000` (5 minutes — Feishu default), the same `(source, id)` arriving 400 seconds later returns `{:ok, :published}`. With `dedupe_ttl_ms: 259_200_000` (72 hours — GitHub default), the same `(source, id)` arriving 24 hours later still returns `{:ok, :duplicate}`.

### 11.9 Policy pipeline

21. A gater returning `:allow` -> Bus receives the original signal.
22. A gater returning `:deny` -> `publish_inbound/1` returns `{:error, {:policy_denied, :gating, _, _}}`; Bus does not see the signal; Deduper is not marked.
23. A gater raising under `:deny` fallback -> same as (22). Under `:allow_with_flag` fallback -> `{:ok, :published}` with `extensions["bullx_flags"]` containing an `:error_fallback` flag.
24. A gater timeout is handled per `policy_timeout_fallback`.
25. A moderator returning `:reject` -> pipeline halts; Bus does not receive the signal.
26. A moderator returning `:flag` -> Bus receives the signal with the flag (`extensions["bullx_flags"]` accumulates).
27. A moderator returning `:modify` -> Bus receives the modified signal with `extensions["bullx_moderation_modified"] = true`.
28. A moderator `:modify` returning an invalid shape -> `{:error, {:moderation_invalid_return, _, _}}`.
29. `Security.verify_sender` returning `{:deny, _, _}` -> `{:error, {:security_denied, :verify, _, _}}`; Deduper is not marked (so the next event from a now-authorised sender can enter).
30. `Security.sanitize_outbound` (RFC 0003) stripping URLs -> the adapter receives the sanitized delivery, and `delivery.succeeded` reflects the sanitized content.
31. Pipeline ordering: the `publish_inbound:stop` event for a Security-denied input has `policy_outcome: :denied_security`.
32. Dedupe fidelity: a Security-denied event re-arriving with the same id is still security-denied (not a duplicate); after a successful publish, the same id is `:duplicate`.
33. Zero defaults: with no `:bullx, :gateway` config, every Input passes through unchanged (no flag, no modify).
34. Telemetry events: the seven events listed in §6.8.6 fire as specified — `publish_inbound` and `deliver` spans (start/stop/exception) plus one `[:bullx, :gateway, :delivery, :finished]` per terminal delivery with `metadata.outcome ∈ {:sent, :degraded, :failed}` and `measurements.attempts`.

### 11.10 Boundary isolation

35. Gateway Core code does not depend on `Plug.Conn`, does not define raw_body / query / remote_ip (`Webhook.RawBodyReader` is an optional helper, not part of the Adapter behaviour); GitHub / Shopify webhook signature verification logic lives entirely inside the respective adapters.
36. Webhook listeners are self-hosted by their adapters; concrete webhook implementation details belong to the adapter's RFC, not to the Gateway Core RFC.
37. Gateway Core may use `BullX.Repo.*` (this RFC supersedes the original "no PostgreSQL" constraint) and may run PostgreSQL migrations; but **no `Oban.insert/1`** — Gateway does not schedule business-level jobs. (DLQ replay uses `BullXGateway.DLQ.ReplayWorker` partitioned workers, defined in RFC 0003, not Oban.)
38. Any inbound signal's `extensions` contains non-empty `bullx_channel_adapter` / `bullx_channel_id`; `scope_id` / `thread_id` live in `data` and are not duplicated into `extensions`.
39. **`subject` is human-readable only and not part of any routing path.** A signal whose `subject` has been deliberately scrambled (e.g. wrong adapter prefix, missing scope segment, garbled separator) must still be routed correctly by Runtime / subscribers consuming `extensions["bullx_channel_adapter"]`, `data["event"]["type"]`, `data["event"]["name"]`, and `data["refs"]`. No Gateway code path or documented consumer pattern parses `subject` for routing decisions.
40. Every Gateway adapter implements `connectivity_check/2`, returns `{:ok, %{status: :ok, ...}}` only for credentials/endpoints that are usable by that adapter, and returns safe string-keyed error maps for failures.
41. Setup/control-plane adapter config validation accepts nested objects and arrays, rejects duplicate enabled `{adapter, channel_id}` pairs, and converts valid enabled entries into the runtime `{{adapter, channel_id}, module, config}` list.
42. `bullx.gateway.adapters` database overrides can represent the same adapter list as `config :bullx, :gateway, adapters`, and invalid database values fall through according to RFC 0001 without crashing boot.
43. A save attempt that changes an enabled adapter after its last connectivity success is rejected until the changed adapter passes `connectivity_check/2` again.

(Outbound boundary criteria belong to RFC 0003.)

## Appendix A: `jido_signal` fact-check summary

Verified against the local source at `~/Projects/jido/jido_signal/lib`:

1. **`Jido.Signal.Bus.subscribe/3` routes by path pattern** — `jido_signal/lib/jido_signal/bus.ex`; pattern semantics come from `Jido.Signal.Router`.
2. **`Jido.Signal.new/1` may explicitly override `id`** — when `id` is omitted, `Jido.Signal.ID.generate!()` (UUID7) is invoked.
3. **`time` is an ISO8601 string** — `new/1` defaults to `DateTime.utc_now() |> DateTime.to_iso8601()`.
4. **`specversion` must be exactly `"1.0.2"`** — see `jido_signal/lib/jido_signal.ex:679-680`'s `parse_specversion/1`; other values (including `"1.0"`) return an error.
5. **`extensions` is a free-form map; only the `"dispatch"` / `"correlation"` namespaces are reserved** — BullX standardises on `bullx_*` prefixes.
6. **`Bus.publish/2` performs only structural validation; it does not mutate signals** — `jido_signal/lib/jido_signal/bus.ex:1149-1159`'s `validate_signals/1`.

(Earlier draft material on Bus persistent subscription ack-checkpoint details is no longer relevant; this RFC does not use persistent subscriptions, and durability is the ControlPlane's responsibility.)

## Appendix B: Dependency boundary

Gateway Core dependencies (introduced by this RFC; RFC 0003 inherits and adds nothing new):

- `:jido_signal` — event envelope + Bus.
- `:ecto_sql` + `:postgrex` — accessed through `BullX.Repo` for durable intake and (in RFC 0003) the DLQ.
- `:plug` — **optional dependency** (`{:plug, "~> 1.14", optional: true}`), required only by adapters that use `BullXGateway.Webhook.RawBodyReader` (§6.6). Adapters that do not need RawBodyReader omit it; environments without webhook adapters do not pull Plug into the compile closure.

Other dependencies (`Req`, WebSocket clients, specific source SDKs) are introduced by the corresponding adapter RFCs.

`BullX.Repo` itself is provided by the application (the existing BullX PostgreSQL connection); this RFC adds one new table migration (`gateway_dedupe_seen`, UNLOGGED). RFC 0003 adds one more (`gateway_dead_letters`, UNLOGGED). These are the only two Gateway tables.

## Appendix C: Consistency with `0000_Architecture.md`

`rfcs/plans/0000_Architecture.md`'s subsystem startup order is preliminary scaffolding.

This RFC clarifies:

- **Gateway Core is Runtime's prerequisite infrastructure** (`CoreSupervisor` starts before `Runtime.Supervisor`).
- **`Gateway.AdapterSupervisor` is attached by the application after Runtime is ready** (replacing the original `IngressControl` global switch with a flatter, more explicit mechanism).
- **Gateway requires `BullX.Repo`** (PostgreSQL connection) to be available before `CoreSupervisor`.
- The startup order is therefore adjusted from the draft "Runtime before Gateway" to "Repo -> Gateway.CoreSupervisor -> Runtime.Supervisor -> AdapterSupervisor".

The concrete code-level placement is performed in the implementation RFCs (this RFC and RFC 0003).

## Appendix D: BullX vs. jido ecosystem mapping

This RFC is the result of aligning BullX Gateway with the jido official trio (`jido_chat` + `jido_messaging` + `jido_integration`). The boundary mapping (full table; rows mentioning outbound concerns are flagged so the reader can navigate to RFC 0003):

| jido | BullX Gateway |
| --- | --- |
| `jido_chat` canonical event payload structs (`Incoming` / `ReactionEvent` / `ActionEvent` / `SlashCommandEvent`) | `BullXGateway.Inputs.*` — seven canonical semantic-type structs (§4.3 / §6.3); the library defines the standard event shape and adapters do the mapping |
| `jido_chat.Adapter.capabilities/0` | `BullXGateway.Adapter.capabilities/0` (§6.2) — declares supported ops |
| `jido_chat.Adapter.stream/3` | `BullXGateway.Adapter.stream/3` (§6.2; full egress contract in RFC 0003) — Enumerable stream; the adapter manages throttle / sequence / finalize |
| `jido_messaging.Gating / Moderation / Security` behaviours | `BullXGateway.Gating / Moderation / Security` (§6.8) — pluggable pipeline hooks; defaults empty |
| `jido_messaging.Deduper` + DLQ + replay | `BullXGateway.Deduper` (§7.5, this RFC) + `OutboundDeduper` + `gateway_dead_letters` + `ReplayWorker` (RFC 0003) — ETS hot cache + PostgreSQL durable backing |
| `jido_messaging.DeliveryPolicy.backoff` | `BullXGateway.RetryPolicy` + `Outcome.error.details["retry_after_ms"]` (RFC 0003) |
| `jido_integration.Ingress.admit_webhook` durable intake | `BullX.Gateway.publish_inbound/1` + ack-after-publish dedupe (§6.5, this RFC) |
| `jido_integration.DispatchRuntime` (dispatch queue + retry + dead-letter) | `BullXGateway.Dispatcher` + in-memory `ScopeWorker` + `gateway_dead_letters` (RFC 0003) |
| `jido_integration.ControlPlane` (durable run / attempt storage) | `BullXGateway.ControlPlane` + Store behaviour (§7.4, dedupe callbacks here and dead-letter callbacks in RFC 0003) — single PostgreSQL implementation; dev/test via Ecto sandbox |
| `jido_integration.WebhookRouter.verification` | **Not adopted** — each adapter does its own verification; Gateway only ships `Webhook.RawBodyReader` (§6.6) |
| `jido_integration.ConsumerProjection` generated Sensor / Plugin | **Not adopted** — BullX Runtime calls `Bus.subscribe` directly; no codegen |
| `jido_messaging.Room / Participant / Thread / RoomBinding / RoutingPolicy` | **Not adopted** — flat `{channel, scope_id, thread_id, actor, refs}` covers the surveyed IM and webhook scenarios (Feishu streaming / recall / edit / reaction / card action / group reply / multi-room / multi-channel) |
| `jido_chat.ModalSubmitEvent / ModalCloseEvent` | **Not adopted** — Slack-specific; modal submit is folded into `Action` (§4.3) |

The spirit is consistent: **the carriage layer (including reliability) is small and stable, the domain layer is distributed and extensible, the policy layer is pluggable**. Differences in BullX Gateway:

1. **More than `jido_chat`:** ack-after-publish inbound dedupe; DLQ + replay; pipeline hooks.
2. **Less than `jido_messaging`:** no Room / Participant / Thread business model (lives in Runtime); no persistent Session.
3. **Less than `jido_integration`:** no connector manifest, no generated Sensor, no cross-tenant auth lifecycle.
4. **Unique:** the Gateway-owned `event.type` semantic axis (`message` / `message_edited` / `message_recalled` / `reaction` / `action` / `slash_command` / `trigger`) + the `duplex` axis — these are BullX's specialisations for IM / webhook hybrid scenarios.
