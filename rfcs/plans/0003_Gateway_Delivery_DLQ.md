# RFC 0003: Gateway Delivery + ScopeWorker + DLQ

- **Author**: Boris Ding
- **Created**: 2026-04-22
- **Supersedes**: `rfcs/drafts/Gateway.md` (jointly with RFC 0002)

## 1. TL;DR

This RFC specifies the **egress half** of `BullXGateway`: the protocol, runtime, and operations surface that turn an internal `BullXGateway.Delivery` command into a confirmed effect on an external channel, together with the durable failure path (DLQ) and the manual replay surface that drives it.

The egress surface is defined by four primitives:

1. **`BullXGateway.Delivery`** — a single struct describing one outbound effect (`:send` / `:edit` / `:stream`), JSON-serializable except for the streaming Enumerable.
2. **`BullXGateway.Delivery.Outcome`** — the JSON-neutral result of one delivery, with three statuses (`:sent` / `:degraded` / `:failed`) and a Gateway-owned `error` map.
3. **Two outcome carrier signals** — `com.agentbull.x.delivery.succeeded` and `com.agentbull.x.delivery.failed` — published on `BullXGateway.SignalBus` so any subscriber can correlate by `data.delivery_id`.
4. **`ScopeWorker`** — one process per `{{adapter, channel_id}, scope_id}` that serializes outbound work from an **in-memory queue**, performs retries in memory, and writes a `gateway_dead_letters` row only on a terminal adapter failure that happens while ScopeWorker is alive.

The ScopeWorker is not a durable state machine. On a BEAM crash, any in-flight outbound work is simply lost — no outcome signal and no dead-letter row are emitted for it. Runtime + Oban is the business-layer retry authority and is responsible for re-dispatching outstanding deliveries after a restart.

Durability is provided by a single UNLOGGED PostgreSQL table (`gateway_dead_letters`, UNLOGGED) with replay driven by `BullX.Gateway.replay_dead_letter/1`. There is no in-flight `gateway_dispatches` table and no per-attempt `gateway_attempts` table.

The inbound carrier path, the `BullXGateway.Adapter` behaviour, the `AdapterRegistry`, the `SignalBus`, the policy hook behaviours (`Gating` / `Moderation` / `Security`), and the `ControlPlane` GenServer skeleton are defined in **RFC 0002**. This RFC consumes those primitives and adds everything needed for outbound delivery, including the dead-letter callbacks of the `Store` behaviour, the `ScopeWorker` runtime, the `OutboundDeduper`, the DLQ schema and ops API, and the egress slice of `Retention`.

`exactly-once` is not a Gateway guarantee. The Gateway provides **envelope-level at-least-once with `delivery.id` dedupe and durable terminal-failure capture (while ScopeWorker is alive)**. Business-level exactly-once is the responsibility of `BullX.Runtime` (Oban) and the consuming subsystem.

## 2. Position and boundaries

### 2.1 What this RFC owns

1. The `BullXGateway.Delivery` struct, its `Content` value, and the `Outcome` projection (§5).
2. The `com.agentbull.x.delivery.succeeded` / `.failed` carrier signal envelope and `Outcome.to_signal_data/1` (§4).
3. The egress callbacks of `BullXGateway.Adapter` (`deliver/2` / `stream/3`) and the call contract that `ScopeWorker` follows when invoking them (§6).
4. The `BullX.Gateway.deliver/1` outbound pipeline (§6.3) and `BullX.Gateway.cancel_stream/1`.
5. The in-memory `ScopeWorker` runtime — keying, lifecycle, monitor of adapter subtree, retry classification, backoff, exception boundary (§7.5).
6. The `:stream` Task lifecycle and exit-reason mapping (§7.6).
7. The `OutboundDeduper` (terminal-success-only ETS cache + sweep) and its DLQ-replay bypass rule (§7.7).
8. The DLQ ops API and replay flow (§7.8).
9. The `gateway_dead_letters` table and its migration (§7.4).
10. The egress slice of `Retention` (§7.9).
11. The egress acceptance criteria (§11).

### 2.2 What this RFC explicitly does **not** do

The carrier path for ingress, the `Inputs.*` family, `InboundReceived` typed signal module, `publish_inbound/1`, the `Deduper` for `(source, id)`, the `gateway_dedupe_seen` table, the policy pipeline hook behaviours, and the `Webhook.RawBodyReader` helper are **defined in RFC 0002** and are not redefined here.

In addition, regardless of whether a topic touches ingress or egress, this RFC does not introduce any of the following (cross-cutting non-goals repeated only because they are load-bearing for understanding what `ScopeWorker` does and does not do):

- **No Gateway-level multi-adapter fan-out.** A Runtime that wants the same content delivered through two channels must call `BullX.Gateway.deliver/1` twice, with two distinct `delivery.id` values. `ScopeWorker` never duplicates work across channels.
- **No outbound `Moderation` behaviour.** Outbound policy is the single hook `Security.sanitize_outbound` (defined in RFC 0002). Heavier content shaping (tone, PII strip, persona) belongs in the LLM-context-aware Runtime layer, not in the egress carrier.
- **No `failure_class` enum and no retry taxonomy in the protocol.** The Gateway exposes `error.kind` plus the conventional `details.retry_after_ms` and `details.is_transient`. Runtime decides business-level retry meaning from those plus its own context.
- **No in-flight outbound durability.** The ScopeWorker queue is in-memory only. On a BEAM crash, in-flight deliveries emit no outcome signal and no dead-letter row; Runtime + Oban re-dispatches.
- **No exactly-once semantics.** That belongs to Runtime + Oban. The Gateway provides terminal-failure capture (while ScopeWorker is alive) and at-least-once with `delivery.id` dedupe.
- **No audit-grade rejection persistence on the outbound side.** `Security.sanitize_outbound` denials are reported via telemetry and the synchronous return value; they are not written to PostgreSQL by this RFC.

## 3. Design constraints

The egress runtime adopts the same four constraints that govern the rest of the Gateway:

1. **Single-node.** No cross-node routing, no distributed bus, no global consistency. `ScopeWorker` and `OutboundDeduper` are local.
2. **Minimal outbound persistence.** The only outbound PostgreSQL write is `gateway_dead_letters` (UNLOGGED) on a terminal adapter failure observed while ScopeWorker is alive. There is no in-flight dispatch table and no per-attempt table. dev/test uses Ecto Sandbox; there is no ETS-backed `Store` implementation. (See §7.4 for the rationale.)
3. **Process isolation per scope.** A failure in one `ScopeWorker` (or in the adapter it invokes) must not affect any other `{{adapter, channel_id}, scope_id}`. Adapter exceptions are caught at the `ScopeWorker` boundary; adapter subtree DOWN events terminate only the in-flight `:stream` Tasks owned by the affected scopes.
4. **`BullXGateway.Delivery` is a struct distinct from inbound `Inputs.*`.** Outbound is not a mirror of inbound and is not modelled as a variant of `Jido.Signal`. The Delivery struct is the source-of-truth contract that Runtime constructs and the Gateway acts on.

Two further conventions apply throughout:

- **`Outcome` is JSON-neutral.** Status is a string in the wire form (`"sent"` / `"degraded"` / `"failed"`), `error` is a map with string keys, and `Outcome` itself never reaches `Jido.Signal.data` without going through `Outcome.to_signal_data/1`.
- **`time` is ISO8601.** All Gateway-produced signals use `DateTime.to_iso8601/1` for `time`, and `specversion` is exactly `"1.0.2"` (the parser rejects `"1.0"`).

## 4. Outcome carrier signals

The Gateway publishes two stable outcome `signal.type` values on `BullXGateway.SignalBus` (defined in RFC 0002):

```text
com.agentbull.x.delivery.succeeded         # data corresponds to Outcome{status: :sent | :degraded}
com.agentbull.x.delivery.failed            # data corresponds to Outcome{status: :failed}
```

Production timing:

- `:send` / `:edit` returning `{:ok, Outcome}` from `adapter.deliver/2` → publish `delivery.succeeded`.
- `:stream` reaching its close with `{:ok, Outcome}` from `adapter.stream/3` → publish `delivery.succeeded`.
- `:stream` cut short by explicit cancel or adapter subtree DOWN (while ScopeWorker is alive) → publish `delivery.failed` with `error.kind ∈ {"stream_cancelled", "adapter_restarted"}`. (A BEAM crash is not in this list: there is no outcome signal in that case; Runtime + Oban re-dispatches.)
- Any op failing — unsupported callback, adapter `{:error, _}`, adapter exception, contract violation, or terminal classification after retries — → publish `delivery.failed`.

### 4.1 Envelope

```elixir
%Jido.Signal{
  specversion: "1.0.2",
  id: Jido.Signal.ID.generate!(),                        # one fresh UUID7 per outcome event
  source: "bullx://gateway/#{adapter}/#{channel_id}",
  type: "com.agentbull.x.delivery.succeeded" | "com.agentbull.x.delivery.failed",
  subject: "#{adapter}:#{scope_id}#{if thread_id, do: ":#{thread_id}", else: ""}",
  time: DateTime.utc_now() |> DateTime.to_iso8601(),
  datacontenttype: "application/json",
  data: BullXGateway.Delivery.Outcome.to_signal_data(outcome),  # contains "delivery_id" key
  extensions: %{
    "bullx_channel_adapter" => Atom.to_string(adapter),
    "bullx_channel_id" => channel_id,
    "bullx_caused_by" => delivery.caused_by_signal_id    # omitted when nil
  }
}
```

`subject` is human-readable only; routing must read `extensions` or `data`. `scope_id` and `thread_id` stay in `subject` and are not duplicated into `extensions`.

### 4.2 Why `signal.id ≠ delivery.id`

A single `delivery.id` may produce **multiple** outcome events across its lifetime — most commonly via DLQ replay: the first terminal failure publishes `delivery.failed{data.delivery_id: X}`, and a later successful replay publishes `delivery.succeeded{data.delivery_id: X}`. If both events shared a `signal.id`, Bus history, downstream idempotency, and traces would collapse two distinct events into one.

Therefore:

- **`signal.id`** identifies the outcome event itself. Each publish generates a fresh id via `Jido.Signal.ID.generate!/0`.
- **`data["delivery_id"]`** identifies which delivery the event belongs to. Subscribers correlate by `data.delivery_id` (and, if useful, by `extensions["bullx_caused_by"]`).

Same `delivery.id`, different `signal.id`. Multiple outcomes for one delivery are linked through `data.delivery_id`, but each event remains uniquely addressable in the Bus.

### 4.3 No `notify_pid`

The original draft of `BullXGateway.Delivery` carried a `notify_pid` to receive the outcome out-of-band. **This RFC removes `notify_pid`.** The single subscription contract is:

```elixir
Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.delivery.**",
  dispatch: {:pid, target: my_observer}
)
```

Callers correlate received outcomes by `data.delivery_id` (preferred) or `extensions["bullx_caused_by"]` (when set from the inbound that triggered the delivery). This eliminates the dual-channel ambiguity ("did the result come back through my `notify_pid` or through the Bus?") and aligns the Gateway with the `jido_messaging` "synchronous return + Signal observer" pattern.

`BullX.Gateway.deliver/1` therefore never sends a result message to the caller's mailbox. It returns synchronously with `{:ok, delivery_id}` or an `{:error, _}` from the pre-flight stages, and any later progress is observed on the Bus.

## 5. Outbound protocol

### 5.1 `BullXGateway.Delivery`

```elixir
defmodule BullXGateway.Delivery do
  @type channel :: {adapter :: atom(), channel_id :: String.t()}

  @type op :: :send | :edit | :stream

  @type t :: %__MODULE__{
          id: String.t(),
          op: op(),
          channel: channel(),
          scope_id: String.t(),
          thread_id: String.t() | nil,
          reply_to_external_id: String.t() | nil,
          target_external_id: String.t() | nil,
          content: BullXGateway.Delivery.Content.t() | Enumerable.t() | nil,
          caused_by_signal_id: String.t() | nil,
          extensions: map()
        }
end
```

Field semantics:

- **`id`** — caller-supplied identifier (UUID7 strongly recommended, e.g. `BullX.Ext.gen_uuid_v7/0`). Must be unique per intended effect; reused values are deduped to the original outcome (§7.7).
- **`op`** — one of `:send`, `:edit`, `:stream`. Must match a declared op-capability of the resolved adapter (§6.2).
- **`channel`** — `{adapter_atom, channel_id_string}`. **`channel_id` is always a `String.t()`**, never `term()`. See RFC 0002 §6.1 for the per-binding semantics (one adapter module can be registered under multiple distinct `channel_id` values).
- **`scope_id` / `thread_id`** — same names as `data.scope_id` / `data.thread_id` on inbound signals and as the keys inside `data.reply_channel`. Runtime constructing a Delivery from an inbound reads `data.reply_channel` directly without renaming fields.
- **`reply_to_external_id`** — optional on `:send`. Means "reply to external message _X_". Adapters bridge platform-specific reply semantics (Feishu quote reply, Slack thread reply, etc.). If `thread_id` is also set, both fields are honored according to adapter contract.
- **`target_external_id`** — required for `:edit`. Identifies the external message to mutate.
- **`content`** —
  - For `:send` / `:edit`: a single `BullXGateway.Delivery.Content.t()` (§5.2), or `nil` for adapter-specific edits that carry intent in `extensions`.
  - For `:stream`: any `Enumerable.t()` of chunks. The shape of each chunk is adapter-internal; the Gateway does not interpret stream elements.
- **`caused_by_signal_id`** — the `signal.id` of the inbound that triggered this delivery. Optional but recommended; surfaces as `extensions["bullx_caused_by"]` on the outcome signal (§4.1).
- **`extensions`** — a free-form map of adapter-specific hints (e.g. Feishu `update_multi`). Not part of the outcome envelope.

**Removed in this RFC.** Two fields that earlier drafts carried are explicitly dropped:

- `notify_pid` — see §4.3.
- `stream_token` — the older two-op `:stream_open` / `:stream_chunk` protocol is collapsed into a single `:stream` op driven by `Enumerable`. Stream-internal sequence numbers, message ids, and card ids live entirely inside the adapter implementation; there is no protocol-level token.

#### 5.1.1 The `:stream` op durability boundary

The `content :: Enumerable.t()` of a `:stream` Delivery is a **process-local** value. It lives only inside the ScopeWorker process that runs it.

This is a special case of the general rule: **no in-flight outbound state is persisted at all**. The ScopeWorker queue — `:send`, `:edit`, and `:stream` deliveries alike — is entirely in-memory. A `:stream` delivery whose `content` is an Enumerable cannot be serialized; a `:send` or `:edit` delivery with a concrete `Content` value also lives only in the ScopeWorker until it terminates. If the BEAM (or the `ScopeWorker` process) crashes while a delivery is queued or running:

- **No outcome signal is emitted.** The subscriber never hears from that `delivery.id`.
- **No dead-letter row is written.** The failure is not captured in `gateway_dead_letters`.
- **Runtime + Oban re-issues.** The business-layer retry authority sees that its Oban job never observed a terminal outcome and re-dispatches (typically with the same `delivery.id`; the OutboundDeduper cache is empty, so the fresh attempt proceeds through the adapter normally).

The only durable outbound artefact is a `gateway_dead_letters` row written on a terminal adapter failure that happens while ScopeWorker is alive (§7.5).

### 5.2 `Content`

```elixir
defmodule BullXGateway.Delivery.Content do
  @type kind :: :text | :image | :audio | :video | :file | :card
  @type t :: %__MODULE__{kind: kind(), body: map()}
end
```

The `kind` enum and the per-kind minimum `body` shape are a **shared carrier contract** between outbound and inbound. The full body-shape table — including the **hard rule that every non-`:text` kind MUST carry a non-empty `body["fallback_text"]` string** — is normatively defined in **RFC 0002 §5.2** (the inbound `data["content"]` block contract). RFC 0003 reuses the same table verbatim for `BullXGateway.Delivery.Content.body`.

On the inbound side, `content` is itself the canonical model-facing projection; there is no parallel summary string. The shared body contract therefore has to work for both "what the model reads" and "what the adapter sends".

For orientation only, the six `kind` values are: `:text`, `:image`, `:audio`, `:video`, `:file`, `:card`. Media kinds carry a single `url` field (any URI scheme — `https://` or `data:`); the path / local-file abstraction is intentionally absent. Adapter implementations that receive byte buffers must upload or encode them into a URI before constructing a `Content`.

The `fallback_text` rule is what makes the degradation principle (§6.7) tractable: an adapter that does not natively support `:card` can always fall back to `body["fallback_text"]` and still satisfy the delivery, marking the outcome `:degraded`.

### 5.3 `Outcome`

```elixir
defmodule BullXGateway.Delivery.Outcome do
  @type success_status :: :sent | :degraded
  @type status :: success_status() | :failed

  @type t :: %__MODULE__{
          delivery_id: String.t(),
          status: status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: map() | nil
        }

  @type adapter_success_t :: %__MODULE__{
          delivery_id: String.t(),
          status: success_status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: nil
        }
end
```

Status semantics:

- **`:sent`** — the adapter confirms delivery to the external platform with no degradation.
- **`:degraded`** — the adapter delivered, but had to downgrade the content (e.g. `:card` rendered as `body["fallback_text"]`, media forwarded as a link rather than inline). `warnings` is non-empty (e.g. `["card_fallback_to_text"]`).
- **`:failed`** — the Gateway-owned terminal status. `error` is non-nil.

#### 5.3.1 Adapter success-path return contract

Adapter callbacks `deliver/2` and `stream/3` are restricted on the success path:

- Success: return `{:ok, %BullXGateway.Delivery.Outcome{}}` matching `adapter_success_t()` (`status ∈ {:sent, :degraded}`, `error: nil`).
- Failure: return `{:error, error_map}` (the `error_map` shape is specified below).
- **Forbidden**: `{:ok, %Outcome{status: :failed}}`. `:failed` is a Gateway-owned status that may only be produced by `ScopeWorker` after wrapping an error, exception, contract violation, or attempts-exhausted classification. If an adapter returns `{:ok, %Outcome{status: :failed}}`, `ScopeWorker` treats it as a contract violation: the outcome is normalized to `:failed` with `error.kind = "contract"` and the delivery is dead-lettered.

#### 5.3.2 `error` map

`error` must be a JSON-neutral map with string keys:

```elixir
%{
  "kind" =>
    "rate_limit"
    | "auth"
    | "network"
    | "payload"
    | "exception"
    | "unsupported"
    | "contract"
    | "stream_cancelled"
    | "adapter_restarted"
    | "unknown",
  "message" => "...",
  "details" => %{...}                                    # optional
}
```

Conventional `details` keys (non-mandatory; adapters fill them when available):

- **`details["retry_after_ms"]`** — adapter-suggested wait before the next retry (e.g. derived from a Feishu HTTP `Retry-After` header on a 429). When present, `ScopeWorker` **prefers this value over the default exponential backoff** for the next attempt. (§7.5 retry classification.)
- **`details["is_transient"]`** — adapter-asserted hint that the failure is transient. Runtime and `ScopeWorker` may consult it as additional context, but the protocol does not bind a specific behaviour to it.

**No `failure_class` enum.** The Gateway deliberately does **not** lift `:transient | :permanent | :ambiguous` (or any similar taxonomy) into the protocol:

- `ScopeWorker` performs a narrow, kind-based classification for retry-vs-terminal (§7.5). That classification is local to the Gateway and not exposed on the wire.
- Runtime decides business-level retry meaning from `error.kind`, `details`, and its own context. "Was a network read-timeout ambiguous?" is not a question the Gateway protocol answers.

Adapters are expected to swallow short-lived transient blips internally (e.g. one or two adapter-internal retries against a 503) and report only the final result to the Gateway.

#### 5.3.3 `Outcome.to_signal_data/1`

`Outcome` cannot be placed directly into `Jido.Signal.data` — the data field must be JSON-neutral. The Gateway projects it as follows:

```elixir
BullXGateway.Delivery.Outcome.to_signal_data(outcome) :: %{
  "delivery_id" => String.t(),
  "status" => "sent" | "degraded" | "failed",
  "external_message_ids" => [String.t()],
  "primary_external_id" => String.t() | nil,
  "warnings" => [String.t()],
  "error" => map() | nil
}
```

Success projection:

```elixir
%{
  "delivery_id" => "dlv_123",
  "status" => "sent",
  "external_message_ids" => ["msg_1"],
  "primary_external_id" => "msg_1",
  "warnings" => [],
  "error" => nil
}
```

Failure projection:

```elixir
%{
  "delivery_id" => "dlv_123",
  "status" => "failed",
  "external_message_ids" => [],
  "primary_external_id" => nil,
  "warnings" => [],
  "error" => %{
    "kind" => "rate_limit",
    "message" => "Feishu API 429 Too Many Requests",
    "details" => %{"retry_after_ms" => 3000}
  }
}
```

Notes:

- `signal.data["status"]` is a string, not an atom.
- The projection is also responsible for canonicalizing any atom-keyed `details` into string-keyed maps if an adapter constructs the error map with atoms.

### 5.4 Stream protocol

Stream is **one** op, not three. The shape is a single `:stream` Delivery whose `content` is an `Enumerable.t()`:

```elixir
%BullXGateway.Delivery{
  id: dlv_id,
  op: :stream,
  channel: {:feishu, "default"},
  scope_id: "oc_xxx",
  thread_id: nil,
  content: Stream.unfold(...)                 # any Enumerable of chunks
}
```

Adapter side:

```elixir
@callback stream(
            delivery :: BullX.Delivery.t(),
            enumerable :: Enumerable.t(),
            context :: BullXGateway.Adapter.context()
          ) :: {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}
```

The adapter consumes the Enumerable and is responsible for all platform mechanics (e.g. Feishu's `cardkit.v1.card.create` placeholder, `cardkit.v1.cardElement.content` incremental updates, `card.settings` finalize).

#### 5.4.1 Cancel vs. Interrupt

- **Cancel**: `BullX.Gateway.cancel_stream(delivery_id)` calls into the owning `ScopeWorker`, which executes `Task.shutdown(task, :brutal_kill)`. The adapter `stream/3` reducer **should** attempt a finalize when it receives `exit` (e.g. patch the card to "Cancelled" and return `{:error, %{"kind" => "stream_cancelled", ...}}`). If the adapter cannot finalize in time, `ScopeWorker` synthesizes the failure path (§7.6).
- **Interrupt**: there is no separate API. To soft-interrupt an in-flight stream, Runtime simply enqueues a new Delivery (typically `:edit` against the placeholder `target_external_id`). Same-scope serialization (§7.5) means the new Delivery is not executed until the stream completes; this gives a soft "follow-up replaces in progress" behaviour without a separate cancel.

#### 5.4.2 No protocol-level revision / snapshot

The Gateway does not know the shape of stream content and does not need to. Adapters that need to defend against out-of-order updates (e.g. Feishu's `sequence` parameter) maintain those internally and **do not leak them into `Outcome`**.

#### 5.4.3 Adapter-side stream UX responsibilities

Not protocol-binding, but the recommended adapter pattern. Implementations should:

1. **Placeholder first frame.** Before the first chunk arrives, post a placeholder external message ("Thinking…") and remember its `external_message_id`. This avoids a long visible silence.
2. **Throttling / coalescing.** LLM token rates exceed 100Hz; IM platforms accept ~10Hz updates. Adapters MUST debounce or coalesce internally (e.g. 100ms throttle with merged pending text).
3. **Platform idempotency.** Maintain whatever per-platform idempotency tokens are required (Feishu monotonic `sequence` + UUID v7, Slack `client_msg_id`, etc.) inside the adapter.
4. **Finalize.** On stream close, patch the message or card to a terminal form (e.g. Feishu `streaming_mode: false` and a summary populated from the first ~80 characters).
5. **Graceful cancel.** Honor `Task.shutdown` exits by attempting a best-effort finalize before returning `{:error, %{"kind" => "stream_cancelled"}}`.
6. **Platform rate-limit response.** Translate platform 429s into adapter-internal slowdown + bounded retry; do not surface every 429 to the Gateway as a top-level retryable error.
7. **Card structure.** For rich interactive streams, accept `delivery.content.kind = :card` as the initial card schema. Platforms with native client-side streaming animation (Feishu `streaming_config.print_frequency_ms`) place that configuration in the initial card payload. The Gateway treats card payloads as opaque.

## 6. Adapter egress contract

The full `BullXGateway.Adapter` behaviour is defined in **RFC 0002**, including `adapter_id/0`, `child_specs/2`, the `context()` type, and the two-axis `capabilities/0` (op-capabilities and metadata-capabilities). This section elaborates only what the egress runtime requires from those callbacks.

### 6.1 Egress callbacks

```elixir
@callback deliver(BullX.Delivery.t(), context()) ::
            {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

@callback stream(BullX.Delivery.t(), Enumerable.t(), context()) ::
            {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

@optional_callbacks [
  child_specs: 2,
  deliver: 2,
  stream: 3
]
```

Required at the runtime call site:

- The `context` passed by `ScopeWorker` carries at minimum `%{channel: BullX.Delivery.channel(), config: map(), telemetry: map()}` and may carry adapter-supplied additional keys (notably the adapter subtree anchor pid for `Process.monitor`, see §7.5).
- `deliver/2` handles `op = :send` and `op = :edit`. The adapter must declare `:send` and/or `:edit` in `capabilities/0`.
- `stream/3` handles `op = :stream`. The adapter must declare `:stream` in `capabilities/0`.
- An adapter that does not export the relevant callback **and** does not declare the corresponding op-capability is treated as not supporting that op. The egress pipeline detects this via `capabilities/0` (§6.3 step 3) without invoking an undefined callback.

### 6.2 Op vs. metadata capability semantics (egress)

The two-axis split established in RFC 0002 §6.2 has direct egress consequences:

- **Op-capabilities** (`:send | :edit | :stream`) are **one-to-one with `BullX.Delivery.op()`** and are the **only** capability axis that `BullX.Gateway.deliver/1` consults during pre-flight. If the resolved adapter does not declare the requested op, the pipeline immediately publishes `delivery.failed{error.kind = "unsupported"}` and writes `gateway_dead_letters` (§6.3 step 3).
- **Metadata capabilities** (`:reactions | :cards | :threads | …` — adapter-defined atoms) are **self-description for UI / Runtime / skill consumption only**. The Gateway **does not** pre-check them. Concretely, with the `:cards` example: a Runtime sends `Delivery{op: :send, content: %{kind: :card, …}}` to an adapter whose `capabilities/0` returns `[:send]` (no `:cards`). The Gateway **still casts** the delivery to `ScopeWorker` and invokes `adapter.deliver/2`. The adapter is expected to fall back to the card body's `body["fallback_text"]` and return `{:ok, %Outcome{status: :degraded, warnings: ["card_fallback_to_text"]}}`. **The only reason `deliver/1` rejects a `:send` is the absence of `:send` itself, never the absence of `:cards`.**

This is the load-bearing realisation of the degradation principle (§6.4): degradation is decided by the adapter against the `fallback_text` contract, not by the Gateway against a metadata-capability table.

### 6.3 The `deliver/1` outbound pipeline

```elixir
@spec BullX.Gateway.deliver(BullX.Delivery.t()) ::
        {:ok, delivery_id :: String.t()}
        | {:error, {:invalid_delivery, term()}}
        | {:error, {:unknown_channel, BullX.Delivery.channel()}}
        | {:error, {:security_denied, :sanitize, atom(), String.t()}}
```

Steps:

1. **Delivery shape validation.** Validate the struct fields (id non-empty, op ∈ `:send | :edit | :stream`, channel `{atom, string}`, scope_id non-empty, content shape matches op, etc.). On failure return `{:error, {:invalid_delivery, reason}}`. **Do not** publish `delivery.failed`. **Do not** write to PostgreSQL.
2. **Channel lookup** in `BullXGateway.AdapterRegistry` (RFC 0002). If the `{adapter, channel_id}` pair is not registered, return `{:error, {:unknown_channel, channel}}`. **Do not** publish `delivery.failed`. **Do not** write to PostgreSQL.
3. **Capability pre-flight.** Read `adapter.capabilities/0`. If `delivery.op` is not declared: publish `delivery.failed{error.kind = "unsupported"}` (envelope per §4.1, with `data` produced by `Outcome.to_signal_data/1`) and write a `gateway_dead_letters` row capturing the original delivery as `payload`. Return `{:ok, delivery.id}`. (Note: the function still returns success because the failure has been observably recorded; the caller correlates by `data.delivery_id` on the Bus.) **Metadata-capabilities are not checked here** (§6.2).
4. **`Security.sanitize_outbound`.** Invoke the configured `Security` adapter (behaviour defined in RFC 0002). Possible outcomes:
   - `{:ok, sanitized_delivery}` → continue with `sanitized_delivery`.
   - `{:ok, sanitized_delivery, metadata_map}` → continue with `sanitized_delivery`; the metadata map is consumed by the policy pipeline and is otherwise opaque to the egress runtime.
   - `{:error, reason}` (or `:deny` shapes per the behaviour) → return `{:error, {:security_denied, :sanitize, reason_atom, description}}`. **Do not** publish a `delivery.*` outcome (the synchronous return is the result; telemetry records the decision).
5. **`OutboundDeduper.seen?(delivery.id)`** (§7.7). The deduper caches **only terminal-success** outcomes. If the delivery.id is present:
   - Re-publish a `delivery.succeeded` carrying the cached outcome but with `warnings: ["duplicate_delivery_id"]` appended. The new `signal.id` is freshly generated (§4.2); `data.delivery_id` is the cached delivery.id.
   - **Do not** invoke the adapter.
   - Return `{:ok, delivery.id}`.

   If not present, continue.
6. **Resolve `ScopeWorker`** via `BullXGateway.ScopeRegistry`, starting one under `BullXGateway.Dispatcher` (a `DynamicSupervisor`) if absent. The registry uses the `{:via, …}` lookup-or-start pattern atomically to avoid losing a cast across a `terminate` race.
7. **`ScopeWorker.enqueue(channel, scope_id, delivery)`** — `GenServer.cast` with the full `%BullXGateway.Delivery{}` struct; the worker stores it in its in-memory delivery map. No DB write happens at enqueue time.
8. **Return `{:ok, delivery.id}`.**

**DLQ replay does not enter this pipeline.** `replay_dead_letter/1` (§7.8) rebuilds the `%Delivery{}` from the dead-letter row and calls `ScopeWorker.enqueue/3` directly, **skipping step 3 (capability pre-check) and step 5 (OutboundDeduper)**:

- Capability was already accepted at original enqueue. If a capability has since been removed from the adapter (e.g. `:cards` was dropped between enqueue and replay), degradation happens adapter-side via `fallback_text`, exactly as it would for a normal new delivery (§6.2).
- OutboundDeduper would be empty of this delivery.id (only terminal successes are cached), but skipping the lookup avoids a misclassification path entirely. (See §7.7 for the full bypass rationale.)

### 6.4 Degradation principles

Degradation is the adapter's responsibility. The Gateway enforces only two hard rules:

1. **The Gateway does not invent business fallback commands.** A Runtime that wants to send a card MUST provide `body["fallback_text"]` (§5.2 hard rule). An adapter that does not natively support cards delivers `fallback_text` as plain text. The adapter does not invent business-level fallback (e.g. it does not paraphrase, summarize, or restructure content).
2. **Degradation must be observable.** When degradation occurs, the adapter returns `Outcome{status: :degraded, warnings: [...]}` with at least one descriptive warning (`"card_fallback_to_text"`, `"audio_dropped_no_native_support"`, etc.). Silent degradation is a contract violation.

These two rules are what make the metadata-capability axis usable as a **hint** without making it a gating predicate.

## 7. Egress runtime

### 7.1 Lifecycle (recap)

The Gateway's startup ordering is fully specified in RFC 0002 §7.1. For the egress half, the relevant ordering is `Repo → Gateway.CoreSupervisor → Runtime.Supervisor → AdapterSupervisor`. `ScopeWorker` instances live under `BullXGateway.Dispatcher` (a `DynamicSupervisor` child of `CoreSupervisor`); they are started **lazily** on the first `deliver/1` for a given `{{adapter, channel_id}, scope_id}`. There is no boot-time recovery scan — the ScopeWorker holds no durable state, so there is nothing to rebuild at boot. Workers invoke the adapter module registered in `AdapterRegistry`; when a channel was started by `AdapterSupervisor.start_channel/3`, the registry config also carries the per-channel supervisor pid as `anchor_pid`.

### 7.2 Core supervisor children added by this RFC

The `BullXGateway.CoreSupervisor` tree defined in RFC 0002 (with the inbound children: `ControlPlane`, `SignalBus`, `AdapterRegistry`, `Deduper`, the inbound slice of `Retention`, and `Telemetry`) is extended by the following children for the egress half:

```text
BullXGateway.CoreSupervisor
├── … inbound children defined in RFC 0002 …
├── BullXGateway.Dispatcher              # DynamicSupervisor of ScopeWorker
├── BullXGateway.ScopeRegistry           # Registry; via tuple naming for ScopeWorker
├── BullXGateway.OutboundDeduper         # ETS + 5–10min TTL + sweep
├── BullXGateway.DLQ.ReplaySupervisor    # Registry + N partitioned ReplayWorker(s)
└── BullXGateway.Retention               # extended with egress sweep (see §7.9)
```

`BullXGateway.AdapterSupervisor` sits outside `CoreSupervisor` and is started by the application after `Runtime.Supervisor` is ready, exactly as in RFC 0002. It owns one per-channel supervisor for each configured adapter channel; that channel supervisor wraps the child specs returned by `adapter.child_specs/2` and is the anchor pid observed by egress ScopeWorkers.

Notes:

- **`Dispatcher`** is a `DynamicSupervisor` named `BullXGateway.Dispatcher`. It supervises one `ScopeWorker` per `{{adapter, channel_id}, scope_id}` actually in use.
- **`ScopeRegistry`** is a `Registry` named `BullXGateway.ScopeRegistry` used as the via-tuple name source for `ScopeWorker` processes (`{:via, Registry, {BullXGateway.ScopeRegistry, {channel, scope_id}}}`).
- **`OutboundDeduper`** is a single GenServer owning a public ETS table, plus a periodic sweep timer (§7.7).
- **`DLQ.ReplaySupervisor`** is a small subtree (a `Registry` + `N` worker GenServers, partitioned by `:erlang.phash2/2`); see §7.8.
- **`Retention`** already exists from RFC 0002 for inbound retention; this RFC adds the outbound sweep responsibilities (§7.9).

### 7.3 ControlPlane Store: dead-letter callbacks

The `BullXGateway.ControlPlane.Store` behaviour is declared in RFC 0002. The dead-letter callbacks that this RFC implements are:

```elixir
defmodule BullXGateway.ControlPlane.Store do
  # … dedupe callbacks (see RFC 0002) …

  @callback put_dead_letter(map()) :: :ok | {:error, term()}
  @callback fetch_dead_letter(dispatch_id :: String.t()) :: {:ok, map()} | :error
  @callback list_dead_letters(filters :: keyword()) :: {:ok, [map()]}
  @callback increment_dead_letter_replay_count(dispatch_id :: String.t()) :: :ok | {:error, term()}
  @callback delete_old_dead_letters(before :: DateTime.t()) :: {:ok, non_neg_integer()}

  @callback transaction((module() -> result)) :: {:ok, result} | {:error, term()}
end
```

There are no dispatch or attempt callbacks — those tables no longer exist. `purge_dead_letter/1` is exposed on `BullXGateway.ControlPlane.Store.Postgres` directly (as a convenience function), not as a behaviour callback.

There is exactly one production implementation: `BullXGateway.ControlPlane.Store.Postgres`, backed by `BullX.Repo`. dev/test runs against the same Postgres adapter under Ecto Sandbox; there is no ETS-backed implementation. The behaviour is preserved for future pluggability and for Mox-based unit tests, **not** for environment differentiation.

### 7.4 Outbound table migrations

One table is added by this RFC: `gateway_dead_letters` (UNLOGGED). The migration uses `execute("CREATE UNLOGGED TABLE ...")` paired with `execute("DROP TABLE ...")` for `down`.

#### 7.4.1 `gateway_dead_letters` (UNLOGGED)

Holds terminally-failed deliveries as failure evidence. This is the only outbound-side Gateway table.

| Column | Type | Notes |
| --- | --- | --- |
| `dispatch_id` | text PK | same value as the original `delivery.id` |
| `op` | text | |
| `channel_adapter` | text | |
| `channel_id` | text | |
| `scope_id` | text | |
| `thread_id` | text NULL | |
| `caused_by_signal_id` | text NULL | |
| `payload` | jsonb | the original Delivery payload (minus `:stream` Enumerable, per §5.1.1) |
| `final_error` | jsonb | the terminal `error` map |
| `attempts_total` | integer | cumulative attempt count for this delivery before it was dead-lettered |
| `attempts_summary` | jsonb NULL | optional rollup of the last N error maps for human inspection |
| `dead_lettered_at` | timestamptz | |
| `replay_count` | integer DEFAULT 0 | incremented by `replay_dead_letter/1` |

Indexes:

- `(channel_adapter, channel_id, scope_id, dead_lettered_at DESC)` — drives `list_dead_letters/1` filtered by channel and scope.
- `(dead_lettered_at DESC)` — drives the default ops feed and the 90-day Retention sweep.

#### 7.4.2 Rationale for UNLOGGED

| Table | Persistence | Why |
| --- | --- | --- |
| `gateway_dead_letters` | **UNLOGGED** | Failure evidence for ops; loss on unclean server crash is acceptable because Runtime + Oban re-dispatches, and a fresh terminal failure writes a new row. Surviving clean shutdowns and ordinary operation is all the carrier owes here. |

The whole Gateway schema is now two UNLOGGED tables: `gateway_dedupe_seen` (RFC 0002) and `gateway_dead_letters` (this RFC). The Gateway's reliability boundary is **carrier-level correctness** (the inbound policy pipeline runs before publish; dedupe holds across retries; terminal outbound failures while ScopeWorker is alive are observable in the DLQ). It is **not** "every intermediate state is persisted across server crashes". Runtime + Oban is the business retry layer; the adapter is the external-source ack layer; the DLQ is what the carrier owes for failures it has given up on.

### 7.5 Egress: `Dispatcher` + `ScopeWorker`

`ScopeWorker` is keyed by `{{adapter, channel_id}, scope_id}`. Same key → serialized; different keys → independent and parallel.

#### 7.5.1 Responsibilities

- Serialize deliveries for the same `{channel, scope_id}`.
- Hold the in-memory queue (list of `delivery.id` values) and the delivery map (`delivery.id -> %Delivery{}`).
- Track the per-delivery attempt counter in process state.
- Track the `Task` ref of any in-flight `:stream` so it can be cancelled.
- `Process.monitor` the adapter subtree anchor pid (the adapter exposes this via `context`). On adapter subtree DOWN, terminate any in-flight `:stream` Task owned by this ScopeWorker.
- Catch any exception thrown by an adapter callback (§7.5.3) and produce a normalized `Outcome{status: :failed}`.
- Hibernate after 60s idle; terminate after 5 minutes idle. The `ScopeRegistry` via-tuple lookup-or-start handles the terminate-races (a delivery cast that arrives during termination starts a fresh worker).

#### 7.5.2 Per-attempt execution

`ScopeWorker.enqueue(channel, scope_id, delivery)` casts the full `%Delivery{}` to the worker, which stores it in the in-memory delivery map and appends `delivery.id` to the queue. When the worker is idle it takes the head off the queue and starts an attempt.

For each delivery the worker handles:

1. Increment the in-memory attempt counter for this `delivery.id`.
2. Invoke the adapter inside the exception boundary (§7.5.3):
   - `:send` / `:edit` → `adapter.deliver(delivery, context)`.
   - `:stream` → `Task.Supervisor.async_nolink(..., fn -> adapter.stream(delivery, enumerable, context) end)` and await the Task; see §7.6 for Task lifecycle.
3. **Success path.** Adapter returned `{:ok, %Outcome{status: :sent | :degraded}}`:
   - Publish `delivery.succeeded` on `SignalBus` (envelope per §4.1).
   - **`OutboundDeduper.mark_success(delivery.id, outcome)`** (the **only** place mark_success is called; see §7.7).
   - Forget the delivery from the in-memory map.
4. **Retryable failure.** Adapter returned `{:error, error_map}` classified as retryable AND `next_attempt < max_attempts`:
   - Compute backoff (§7.5.4).
   - `Process.send_after(self(), {:run, delivery.id}, backoff_ms)`.
5. **Terminal-or-exhausted failure.** Either retryable AND `next_attempt >= max_attempts`, or non-retryable:
   - `Store.put_dead_letter(%{dispatch_id: delivery.id, final_error: error_map, attempts_total: next_attempt, payload: encode_delivery_payload(delivery), …})`.
   - Publish `delivery.failed` on `SignalBus`.
   - **Do not** mark `OutboundDeduper`.
   - Forget the delivery from the in-memory map.

**No crash recovery from the database.** The ScopeWorker has no `init/1` scan and the `ControlPlane` has no boot-time sweep for outbound work. All in-flight state lives in ScopeWorker process memory. On a BEAM crash the state is lost; Runtime + Oban observes that its Oban job never received a terminal outcome signal and re-dispatches.

#### 7.5.3 Adapter exception boundary

Every adapter call is wrapped:

```elixir
try do
  call_adapter(adapter, delivery, ctx)
rescue
  e -> {:error, %{"kind" => "exception", "message" => Exception.message(e)}}
catch
  kind, reason -> {:error, %{"kind" => "exception", "message" => "#{kind}: #{inspect(reason)}"}}
end
```

The result is fed back into the success / retryable / terminal classification. An adapter that raises is observationally indistinguishable from one that returned `{:error, %{"kind" => "exception", ...}}`. ScopeWorker itself does not crash on adapter exceptions.

#### 7.5.4 Retry classification and backoff

The default `BullXGateway.RetryPolicy`:

- **Retryable kinds**: `error.kind ∈ {"network", "rate_limit"}` plus `"exception"` and `"unknown"`.
- **Terminal kinds**: `error.kind ∈ {"auth", "payload", "unsupported", "contract"}`.
- **`stream_cancelled`** is terminal (no automatic retry). DLQ replay can still re-issue it, but there is no auto-retry.

Per-adapter `RetryPolicy` overrides may extend or restrict these sets; the `RetryPolicy` resolved by the ScopeWorker from the `AdapterRegistry` entry is what the retry classifier consults.

Backoff:

- If `error.details["retry_after_ms"]` is present, use it verbatim (capped at `max_backoff_ms`).
- Otherwise: `min(base_backoff_ms * 2^(attempts - 1), max_backoff_ms)`.
- Defaults: `base_backoff_ms: 1000`, `max_backoff_ms: 30_000`, `max_attempts: 5`.

### 7.6 Stream handling

For `op = :stream`, `ScopeWorker` uses `Task.async_nolink` so the adapter's blocking stream consumption does not block ScopeWorker's mailbox and does not link the failure modes to ScopeWorker's lifecycle:

```elixir
task = Task.Supervisor.async_nolink(
  BullXGateway.Dispatcher.TaskSupervisor,
  fn -> adapter.stream(delivery, enumerable, ctx) end
)
```

ScopeWorker stores the `task.ref` against `delivery.id`.

#### 7.6.1 Cancel

`BullX.Gateway.cancel_stream(delivery_id)`:

1. Look up the owning `ScopeWorker` via `ScopeRegistry`.
2. ScopeWorker calls `Task.shutdown(task, :brutal_kill)`.
3. The adapter's stream reducer **should** observe the `exit`, attempt a best-effort finalize (e.g. patch the placeholder card to "Cancelled"), and return `{:error, %{"kind" => "stream_cancelled", "message" => "..."}}`.
4. If the adapter cannot return in time, the Task exits with `:killed` / `:shutdown` (see §7.6.3) and ScopeWorker synthesizes the failure path.

#### 7.6.2 Adapter subtree DOWN via `Process.monitor`

ScopeWorker `Process.monitor`s the adapter subtree anchor pid that `AdapterSupervisor.start_channel/3` stores in `AdapterRegistry` config and exposes through `context`. On `{:DOWN, _ref, :process, _pid, _reason}`:

- For every in-flight `:stream` Task owned by this ScopeWorker: `Task.shutdown(task, :brutal_kill)`.
- The Task exit is then handled per §7.6.3.

#### 7.6.3 Task exit-reason mapping

ScopeWorker handles Task `:DOWN` messages:

- **`:normal` with `{:ok, %Outcome{}}`** → §7.5 step 4 (success path).
- **`:normal` with `{:error, error_map}`** → §7.5 step 5 or 6 (classification).
- **`:killed` / `:shutdown`** without an adapter return:
  - If `cancel_stream/1` initiated the shutdown → synthesize `{:error, %{"kind" => "stream_cancelled", "message" => "Adapter did not return before shutdown"}}` and route to step 6.
  - If a monitored adapter subtree DOWN initiated the shutdown → synthesize `{:error, %{"kind" => "adapter_restarted", "message" => "Adapter subtree DOWN during stream"}}` and route to step 6.

#### 7.6.4 Mid-flight is not durable

There is no per-chunk persistence and no per-attempt persistence. A `:stream` attempt lives entirely in the ScopeWorker process memory + the `Task` process. On close, either a terminal success (no DB write; only the DLQ on terminal failure) or a terminal failure (`gateway_dead_letters` row) is produced.

### 7.7 `OutboundDeduper`

A dedicated GenServer owning a public ETS table, plus a periodic sweep timer.

- **Storage**: ETS, keyed by `delivery.id`, value `{outcome, expires_at}`.
- **TTL**: 5–10 minutes per entry (default 5 minutes; configurable per adapter via `AdapterRegistry`).
- **Sweep**: a periodic timer (default every 60s) deletes expired entries.

#### 7.7.1 The terminal-success-only rule

`OutboundDeduper` caches **only terminal success**. Concretely, the **only** moment that writes into the cache is `ScopeWorker` after a successful adapter call has published `delivery.succeeded`:

> Inside the success path (§7.5 step 3), **after** `publish delivery.succeeded` has completed, call `OutboundDeduper.mark_success(delivery.id, outcome)`.

Things that explicitly **do not** mark:

- `deliver/1` enqueue does not mark. Marking on enqueue would let DLQ replays be falsely shortcut as duplicates.
- Adapter failure (`{:error, _}` or normalized `Outcome{status: :failed}`) does not mark.
- Terminal dead-letter does not mark.
- Retry-scheduled attempts do not mark (the in-flight retry has not produced a terminal success).

#### 7.7.2 Read path

`deliver/1` step 5 calls `OutboundDeduper.seen?(delivery.id)`. A hit is by construction a **terminal success**:

- Re-publish a `delivery.succeeded` carrying the cached outcome but with `warnings: ["duplicate_delivery_id"]` appended. The `signal.id` is freshly generated (§4.2).
- **Do not** invoke the adapter.
- Return `{:ok, delivery.id}` synchronously.

#### 7.7.3 DLQ replay bypass

`replay_dead_letter/1` (§7.8) **does not consult OutboundDeduper**. The justification is twofold:

- A hit in OutboundDeduper would always be a historical success. But the dispatch being replayed is by construction in `gateway_dead_letters`, i.e. a historical failure. The state cannot be both. Skipping the lookup avoids any chance of misclassifying "this delivery.id failed last time, now please retry" as "we already succeeded for this delivery.id".
- Replays should run end-to-end through the adapter exactly like a fresh attempt (modulo the skipped capability pre-check). After a successful replay, `ScopeWorker` marks OutboundDeduper as it does on any other terminal success.

#### 7.7.4 No mark on inbound or outbound failure

For symmetry with the inbound path: failure-to-publish never leaves a positive dedupe trace. On the outbound side this means a failed adapter attempt or a terminal dead-letter never marks `OutboundDeduper`. A subsequent fresh `deliver/1` with the same `delivery.id` is cast to the ScopeWorker, which simply enqueues it as a fresh delivery. (There is no in-flight UNIQUE constraint, so the caller is responsible for not re-issuing a `delivery.id` already known to be mid-flight; Runtime + Oban's idempotency policy determines this.)

### 7.8 DLQ + Replay

Three ops APIs:

```elixir
@spec BullX.Gateway.replay_dead_letter(dispatch_id :: String.t()) ::
        {:ok, %{status: :replayed, dispatch: map()}}
        | {:error, :not_found | term()}

@spec BullX.Gateway.list_dead_letters(opts :: keyword()) :: {:ok, [map()]}
# opts: :channel, :scope_id, :since, :until, :limit

@spec BullX.Gateway.purge_dead_letter(dispatch_id :: String.t()) :: :ok | {:error, term()}
```

`list_dead_letters/1` returns rows ordered by `dead_lettered_at DESC`. `purge_dead_letter/1` deletes the row outright (use rarely — this destroys the only durable failure evidence).

#### 7.8.1 `replay_dead_letter/1` flow

Routing: requests are dispatched to one of `N` `ReplayWorker` partitions by `:erlang.phash2({:replay, dispatch_id}, N)`. This bounds concurrency per-partition while letting independent dispatch_ids replay in parallel. The `DLQ.ReplaySupervisor` owns the partition workers and a `Registry` for routing.

On a replay request:

1. `Store.fetch_dead_letter(dispatch_id)`. If not present → `{:error, :not_found}`.
2. `Store.increment_dead_letter_replay_count(dispatch_id)` — the dead-letter row is **preserved** as audit evidence; only `replay_count` is incremented.
3. Rebuild a `%BullXGateway.Delivery{}` from the dead-letter row (using `ScopeWorker.decode_delivery_from_dead_letter/1`) and call `ScopeWorker.enqueue(channel, scope_id, delivery)`. The same code path as fresh `deliver/1` from this point onward, **except** capability pre-check is skipped (it was already passed at original enqueue) and OutboundDeduper is bypassed (§7.7.3). Degradation that becomes necessary because adapter capabilities have changed is handled adapter-side via `fallback_text` (§6.2).
4. Return `{:ok, %{status: :replayed, delivery: rebuilt_delivery}}`.

If a replay itself terminally fails, the ScopeWorker's dead-letter write performs a row-level upsert on `dispatch_id` (preserving `replay_count`, overwriting `final_error` and `attempts_total` with the fresh values, and refreshing `dead_lettered_at`). The audit trail keeps growing across multiple replay rounds because `replay_count` was incremented on entry before the adapter was re-invoked.

**`:stream` replay caveat.** A `:stream` delivery rebuilt from a dead-letter row has `content: nil` (the original `Enumerable` was process-local and is not stored). An adapter whose `stream/3` cannot produce a useful result from an absent content payload should observe this and return `{:error, %{"kind" => "payload"}}`, which lands the delivery back in the DLQ. For practical purposes, `:stream` replays are usually not meaningful and should be gated by operator choice.

#### 7.8.2 Access control v1

Access control is out of scope for this RFC; callers are internal (BullXWeb operator console, REPL, ops tooling).

### 7.9 Retention (egress slice)

The `BullXGateway.Retention` GenServer (existing as of RFC 0002 for inbound retention) gains the egress sweep logic in this RFC. It runs hourly by default.

Egress operations:

- **`gateway_dead_letters`** — `DELETE FROM gateway_dead_letters WHERE dead_lettered_at < now() - interval '90 days'`.

The inbound retention rule (`gateway_dedupe_seen`) is defined in RFC 0002 and is not duplicated here.

## 8. Egress sequence walk-throughs

### 8.1 Reply pipeline (Runtime → Gateway → Adapter)

```text
Runtime constructs %BullXGateway.Delivery{}
  -> BullX.Gateway.deliver(delivery)
     - Delivery shape validation
     - Channel lookup (AdapterRegistry)
     - Capabilities pre-check (op-capability only; metadata-capabilities not consulted)
     - Security.sanitize_outbound
     - OutboundDeduper.seen?(delivery.id)
     - ScopeWorker.enqueue(channel, scope_id, delivery)   # in-memory cast
  -> ScopeWorker executes
     - adapter.deliver(delivery, ctx)            for :send / :edit
     - adapter.stream(delivery, enumerable, ctx) for :stream (via Task.async_nolink)
  -> Success            : publish delivery.succeeded + OutboundDeduper.mark_success
  -> Failure (retryable): Process.send_after({:run, id}, backoff)   # in memory
  -> Failure (terminal) : put_dead_letter (UNLOGGED) + publish delivery.failed
```

The canonical pattern for constructing a Delivery from an inbound signal's `data.reply_channel`:

```elixir
reply = inbound.data["reply_channel"]

if reply do
  channel = {String.to_existing_atom(reply["adapter"]), reply["channel_id"]}

  %BullXGateway.Delivery{
    id: BullX.Ext.gen_uuid_v7(),
    op: :send,
    channel: channel,
    scope_id: reply["scope_id"],
    thread_id: reply["thread_id"],
    reply_to_external_id: nil,
    content: %BullXGateway.Delivery.Content{kind: :text, body: %{"text" => "..."}},
    caused_by_signal_id: inbound.id
  }
end
```

Note: `String.to_existing_atom/1` is used because the adapter atom must already exist in the running system (it was registered in `AdapterRegistry`). Construction never invents new atoms from inbound payload data. Runtime may choose to derive the outbound `content` from inbound `data["content"]` when that makes sense, but the carrier contract does not require a one-to-one echo.

### 8.2 Streaming reply pipeline (LLM token stream → Feishu streaming card)

```text
Runtime constructs %BullXGateway.Delivery{op: :stream, content: enumerable_of_chunks, ...}
  -> BullX.Gateway.deliver(delivery)
  -> ScopeWorker Task.async_nolink(fn -> Feishu.Adapter.stream(delivery, enumerable, ctx) end)
  -> Inside Feishu adapter:
     1. cardkit.v1.card.create with placeholder ("Thinking...")
     2. im.v1.message.create attaching card_id -> external_message_id
     3. Consume enumerable; 100ms throttle + merge pending text
     4. cardkit.v1.cardElement.content incremental updates (with monotonic sequence + UUID v7)
     5. enumerable closed -> cardkit.v1.card.settings(streaming_mode: false, summary)
     6. Return {:ok, %Outcome{status: :sent, external_message_ids: [om_xxx], primary_external_id: "om_xxx"}}
  -> ScopeWorker publish delivery.succeeded + OutboundDeduper.mark_success

Cancel path:
  Runtime calls BullX.Gateway.cancel_stream(delivery.id)
  -> ScopeWorker Task.shutdown(task, :brutal_kill)
  -> Adapter stream reducer observes exit -> attempts to patch card to "Cancelled"
                                           -> returns {:error, %{"kind" => "stream_cancelled"}}
  -> ScopeWorker put_dead_letter + publish delivery.failed

Soft-interrupt path:
  Runtime does NOT cancel; instead enqueues new %Delivery{op: :edit, target_external_id: om_xxx, content: new_content}
  -> The new Delivery sits in the ScopeWorker's in-memory queue
  -> Same-scope serialization holds the :edit until the :stream completes
  -> :edit then runs against the same external message
```

## 9. Reliability (egress slice)

The reliability framing established in RFC 0002 §9 carries over. The egress-relevant items are:

1. **Adapter listener supervision.** Adapter subtrees live under `BullXGateway.AdapterSupervisor` (RFC 0002). A crashed adapter restarts and its in-flight `:stream` Tasks are terminated via the `Process.monitor` path on each ScopeWorker; the resulting `Outcome{error.kind: "adapter_restarted"}` is dead-lettered. Egress of one adapter does not affect any other adapter's egress.
2. **Terminal-failure DLQ.** On terminal failure or attempts-exhaustion, a `gateway_dead_letters` row is written by the ScopeWorker while it is alive. In-flight deliveries (anything in the ScopeWorker's in-memory queue or mid-attempt) are not persisted; a BEAM crash loses them and emits nothing. Runtime + Oban is responsible for re-dispatching.
3. **DLQ + manual replay.** `BullX.Gateway.replay_dead_letter/1` rebuilds a Delivery from the dead-letter row and casts the ScopeWorker for the `{channel, scope_id}`. The dead-letter row is preserved (`replay_count` increments) until retention deletes it.
4. **Outbound dedupe.** `delivery.id` dedupe is enforced by `OutboundDeduper` (terminal-success-only ETS, 5–10 min TTL). Failure paths never produce a positive dedupe trace. The Gateway does not provide in-flight collision protection on `delivery.id`; the caller (Runtime + Oban) is expected to not re-issue a `delivery.id` already known to be in-flight.
5. **Telemetry (egress).** The egress surface contributes two items to the Gateway telemetry set defined in RFC 0002 §6.8.6: the `[:bullx, :gateway, :deliver, …]` span (synchronous enqueue verdict) and `[:bullx, :gateway, :delivery, :finished]` (one event per terminal delivery, with `measurements.attempts` and `metadata.outcome ∈ {:sent, :degraded, :failed}`). No per-attempt, per-retry, queue-length, hibernate, OutboundDeduper-hit, or DLQ-write telemetry is emitted; those are inferrable from the terminal event or from Bus-side `delivery.succeeded` / `delivery.failed` subscribers.
6. **UNLOGGED crash semantics (egress subset).** `gateway_dead_letters` is UNLOGGED. On an unclean PostgreSQL server crash it is truncated; this is acceptable because Runtime + Oban re-dispatches outstanding business work and any fresh terminal failure writes a new row.
7. **Envelope-level reliability framing.** The Gateway's outbound contract is **at-least-once with `delivery.id` dedupe and terminal-failure capture (while ScopeWorker is alive)**. `exactly-once` is not a Gateway guarantee; it is a property the consuming subsystem builds on top of `delivery.id` correlation and outcome subscription.

## 10. Non-goals (egress)

- **No Gateway-level multi-adapter fan-out.** Runtime issues `N` `deliver/1` calls.
- **No outbound `Moderation` behaviour.** Outbound policy is the single hook `Security.sanitize_outbound`. (See §2.2.)
- **No `failure_class` enum in the protocol.** `error.kind` plus `details.retry_after_ms` / `details.is_transient` is all the protocol carries; classification is local to ScopeWorker. (See §5.3.2.)
- **No in-flight outbound durability.** The ScopeWorker queue is in-memory. A BEAM crash loses in-flight deliveries silently; Runtime + Oban re-dispatches. (See §5.1.1, §7.5.)
- **No exactly-once semantics** at the Gateway. (See §9.7.)
- **No audit-grade rejection persistence on the outbound side.** `Security.sanitize_outbound` denials are reported via the synchronous return value and telemetry; they are not written to PostgreSQL by this RFC.
- **No `Oban.insert/1` from the Gateway.** Gateway does not schedule business-level jobs. DLQ replay uses partitioned `BullXGateway.DLQ.ReplayWorker`s, not Oban.
- **No `ActorResolver` / business identity bridging on egress.** Identity is set by Runtime when constructing the Delivery. The inbound `actor` carries `{id, display, bot}` only.

## 11. Acceptance criteria

A coding agent has completed this RFC when **all** of the following hold. Numbers are local to RFC 0003 and run from 1.

### 11.1 Delivery + Capability

1. `BullX.Gateway.deliver/1` returns `{:error, {:invalid_delivery, reason}}` for a malformed Delivery and **does not** publish `delivery.failed` and **does not** write any database row.
2. `BullX.Gateway.deliver/1` returns `{:error, {:unknown_channel, channel}}` for an unregistered `{adapter, channel_id}` and **does not** publish `delivery.failed` and **does not** write any database row.
3. `BullXGateway.Adapter.capabilities/0` is a required callback. If the resolved adapter does not declare the requested op-capability (`:send | :edit | :stream`), `deliver/1` publishes `delivery.failed{error.kind = "unsupported"}`, writes a `gateway_dead_letters` row, and returns `{:ok, delivery.id}`.
4. Metadata-capabilities (`:cards | :reactions | :threads | …`) are **not** consulted by `deliver/1`. A Delivery with `op: :send, content: %{kind: :card, ...}` against an adapter declaring `[:send]` (no `:cards`) is cast to ScopeWorker; the adapter is expected to degrade via `fallback_text` and return `Outcome{status: :degraded}`.
5. `Security.sanitize_outbound` returning a deny shape causes `deliver/1` to return `{:error, {:security_denied, :sanitize, reason_atom, description}}`. No `delivery.*` outcome is published.
6. `OutboundDeduper` caches **only terminal-success outcomes** (written by ScopeWorker after `publish delivery.succeeded`). Failed, in-flight, and retry-scheduled attempts do not produce cache entries.
7. A `deliver/1` whose `delivery.id` hits `OutboundDeduper` re-publishes `delivery.succeeded` with `warnings: ["duplicate_delivery_id"]` (signal.id freshly generated per criterion 15), returns `{:ok, delivery.id}`, and **does not** invoke the adapter.
8. `replay_dead_letter/1` does **not** consult `OutboundDeduper`, so a historical failure being replayed cannot be misclassified as a duplicate success.
9. For `Delivery{op: :send | :edit}`: ScopeWorker invokes `adapter.deliver/2`. Adapter `{:ok, Outcome{status: :sent | :degraded}}` → `publish delivery.succeeded + OutboundDeduper.mark_success`. Adapter `{:error, error_map}` classified as retryable AND `attempts < max_attempts` → retry in memory with backoff. Adapter `{:error, error_map}` classified as terminal OR `attempts` exhausted → `put_dead_letter + publish delivery.failed`.
10. Adapter success path is forbidden from returning `{:ok, Outcome{status: :failed}}`. Such a return is treated as a contract violation: ScopeWorker normalizes to `delivery.failed{error.kind = "contract"}` and writes `gateway_dead_letters`.
11. Every `Delivery.Content.kind` value satisfies the §5.2 minimum body shape (kind ∈ enum, body is a map, every non-`:text` kind has a non-empty `body["fallback_text"]` string). `:card` carries `format`, `payload`, `fallback_text`. Media kinds carry a single `url` URI string plus `fallback_text`. Extra fields are allowed.
12. `BullXGateway.Delivery` does **not** carry a `notify_pid` field. Outcome subscription is exclusively via `Bus.subscribe("com.agentbull.x.delivery.**")`. Outcome signals carry `extensions["bullx_caused_by"] = caused_by_signal_id` when the Delivery provided one.
13. When `Outcome.error.details["retry_after_ms"]` is present, ScopeWorker uses it (capped by `max_backoff_ms`) for the next retry instead of the exponential default.

### 11.2 Outcome Signal

14. `BullXGateway.Delivery.Outcome.to_signal_data/1` returns a JSON-neutral string-keyed map with `status` as `"sent" | "degraded" | "failed"` (string, not atom).
15. The `delivery.succeeded` and `delivery.failed` envelopes:
    - `id` is a fresh `Jido.Signal.ID.generate!/0` per outcome event (NOT the `delivery.id`), so multiple outcomes for the same `delivery.id` (e.g. failure then DLQ-replay success) have distinct `signal.id`s linked through `data["delivery_id"]`.
    - `source = "bullx://gateway/#{adapter}/#{channel_id}"`.
    - `subject = "<adapter>:<scope>[:<thread>]"` (human-readable only; not parsed by routing).
    - `extensions` carries `bullx_channel_adapter` and `bullx_channel_id`. When `caused_by_signal_id` is set, `extensions["bullx_caused_by"]` is also present.

### 11.3 ScopeWorker + Stream

16. Deliveries with the same `{channel, scope_id}` are serialized; deliveries across different scopes run in parallel.
17. An adapter that raises (or `throw`s / `exit`s) inside `deliver/2` or `stream/3` does not crash ScopeWorker. ScopeWorker produces `Outcome{status: :failed, error: %{"kind" => "exception", ...}}` and follows the terminal path (`put_dead_letter + publish delivery.failed`).
18. `:stream` op: ScopeWorker uses `Task.async_nolink` to consume the Enumerable. Successful close produces `publish delivery.succeeded + OutboundDeduper.mark_success`.
19. `BullX.Gateway.cancel_stream(delivery_id)` calls `Task.shutdown(task, :brutal_kill)`. If the adapter returns `{:error, %{"kind" => "stream_cancelled"}}` in time, ScopeWorker takes the terminal path with that error. If the Task exits with `:killed` / `:shutdown` first, ScopeWorker synthesizes `error.kind = "stream_cancelled"` and takes the terminal path.
20. Adapter subtree DOWN observed via `Process.monitor` causes ScopeWorker to `Task.shutdown` any in-flight `:stream` and to take the terminal path with `error.kind = "adapter_restarted"`.
21. ScopeWorker hibernates after 60s idle and terminates after 5 minutes idle. `ScopeRegistry` via-tuple lookup-or-start is used to atomically restart a worker on a new cast that arrives during termination.

### 11.4 DLQ + Replay

22. **Outbound transient retry.** With a mock adapter that fails the first two attempts with `error.kind = "network"` and succeeds on the third: `deliver/1` returns `{:ok, id}`; `delivery.succeeded` is observed within ~5s; the adapter callback was invoked exactly three times.
23. **Outbound exhaustion → DLQ.** With a mock adapter that always fails (`error.kind = "network"`) and `max_attempts = 3`: after the third failure, `gateway_dead_letters` contains exactly one row for this `delivery.id` with `attempts_total = 3`, `list_dead_letters/1` includes it, and `delivery.failed` was published.
24. **Terminal short-circuit.** With a mock adapter returning `error.kind = "auth"` on attempt 1: a `gateway_dead_letters` row is written immediately and no further attempts run.
25. **Outbound crash — no recovery from DB.** After a `deliver/1` call for a delivery that never terminates, kill the BEAM mid-attempt. On restart, no outcome signal is emitted for that `delivery.id` and no `gateway_dead_letters` row exists for it. Runtime + Oban observes the missing terminal outcome and re-dispatches per its idempotency policy; the fresh attempt proceeds normally through the adapter.
26. **DLQ replay success.** Starting from the state of criterion 23, switch the mock adapter to success and call `BullX.Gateway.replay_dead_letter(id)`. The `ReplayWorker` rebuilds the Delivery from the dead-letter row and casts the ScopeWorker; the replay attempt completes successfully; `delivery.succeeded` is observed; `OutboundDeduper.seen?(id)` now hits; the `gateway_dead_letters` row is preserved with `replay_count = 1`.
27. **DLQ replay missing id.** `replay_dead_letter("does_not_exist")` returns `{:error, :not_found}`.
28. **Per-adapter dedupe TTL** continues to apply on inbound (criterion in RFC 0002); the egress test exercises that `OutboundDeduper` TTL of 5 minutes does not retain entries past expiry — a successful Delivery with `delivery.id = X`, then 6 minutes later a second `deliver/1` with `delivery.id = X` invokes the adapter (no duplicate shortcut).
29. **Retention.** Manually invoking `BullXGateway.Retention.run_once/0` applies §7.9 cleanup for `gateway_dead_letters` (>90d).
30. **UNLOGGED crash semantics.** Simulate an unclean PostgreSQL **server** crash via `kill -9 <postmaster_pid>` / `docker kill -s KILL <pg_container>` / `pg_ctl stop -m immediate`. After the server restarts, both UNLOGGED tables (`gateway_dedupe_seen` from RFC 0002 and `gateway_dead_letters` from this RFC) are empty. The acceptable loss of dead-letter history is covered by Runtime + Oban re-dispatching outstanding work and any fresh terminal failures writing new rows.

### 11.5 Boundary isolation

31. The Gateway egress code does not call `Oban.insert/1` (Gateway does not schedule business-level jobs). DLQ replay is implemented by partitioned `BullXGateway.DLQ.ReplayWorker` processes routed by `:erlang.phash2/2`, not by Oban.
32. `delivery.*` outcome signals may carry `extensions["bullx_caused_by"]`; envelope keys are restricted to those listed in §4.1 plus the per-RFC-0002 inbound provenance keys (no business payload is leaked into `extensions`).
33. The `context` map passed to `adapter.deliver/2` and `adapter.stream/3` always contains at minimum `%{channel: BullX.Delivery.channel(), config: map(), telemetry: map()}`. When the channel was started by `AdapterSupervisor.start_channel/3`, `context.anchor_pid` is also present and points at the per-channel adapter supervisor. The three required keys are guaranteed by the Gateway egress contract on every call.

If any criterion fails, the RFC is not complete.

## Appendix A: Dependency boundary

This RFC adds **no new package dependencies** beyond what RFC 0002 already requires. Specifically:

- `:jido_signal` (Bus + Signal envelope) — required by RFC 0002.
- `:ecto_sql` + `:postgrex` (via `BullX.Repo`) — already in scope before any Gateway RFC.
- `BullX.Repo` itself — provided by the application.

Adapter-specific HTTP clients, WebSocket clients, or platform SDKs (e.g. `Req`, Feishu / Slack / Discord SDKs) are introduced by per-adapter RFCs, not by this RFC.

This RFC adds one new database migration (`gateway_dead_letters` UNLOGGED). RFC 0002 owns the `gateway_dedupe_seen` migration. These are the only two Gateway tables.

## Appendix B: Consistency with `rfcs/plans/0000_Architecture.md`

`0000_Architecture.md` notes that subsystem startup ordering in RFC 0 is scaffolding only and may be tightened by subsystem RFCs. This RFC does not change the high-level startup sequence beyond what RFC 0002 already establishes — the relevant order remains:

`BullX.Repo → BullXGateway.CoreSupervisor → BullX.Runtime.Supervisor → BullXGateway.AdapterSupervisor`.

The egress runtime additions of this RFC live under `BullXGateway.CoreSupervisor` (`Dispatcher`, `ScopeRegistry`, `OutboundDeduper`, `DLQ.ReplaySupervisor`, and the egress slice of `Retention`), so they come up with the rest of the Gateway core, before Runtime is ready and before any external adapter starts producing inbound traffic.

## Appendix C: Boundary mapping with the jido ecosystem (egress)

For the egress half of the Gateway, the alignment with the jido ecosystem (`jido_chat` + `jido_messaging` + `jido_integration`) is:

| jido | BullX Gateway (egress) |
| --- | --- |
| `jido_chat.Adapter.stream/3` | `BullXGateway.Adapter.stream/3` (§5.4 / §6.1) — Enumerable-driven; throttling, sequencing, finalize all live inside the adapter. |
| `jido_chat.Adapter.capabilities/0` | `BullXGateway.Adapter.capabilities/0` (RFC 0002 §6.2) — two-axis split (op vs. metadata); only op-capabilities gate `deliver/1` (§6.2). |
| `jido_messaging.Security.sanitize_outbound` | `BullXGateway.Security.sanitize_outbound` (behaviour from RFC 0002; egress invocation specified in §6.3 step 4). |
| `jido_messaging.DeliveryPolicy.backoff` | `BullXGateway.RetryPolicy` (§7.5.5) plus `Outcome.error.details["retry_after_ms"]` override (§5.3.2). |
| `jido_messaging.DLQ + replay` | `BullXGateway.DLQ.ReplaySupervisor` + `gateway_dead_letters` (UNLOGGED) + `replay_dead_letter/1` (§7.8). |
| `jido_integration.DispatchRuntime` (dispatch queue + retry + dead-letter) | `BullXGateway.Dispatcher` + in-memory `ScopeWorker` + `gateway_dead_letters` (§7.5 / §7.8). |
| `jido_integration.ControlPlane` (durable run/attempt storage) | `BullXGateway.ControlPlane` dead-letter callbacks (§7.3) — single Postgres implementation, dev/test under Ecto Sandbox. |

Differences worth calling out:

1. The Gateway's egress is a **plain at-least-once carrier** with `delivery.id` dedupe. It does not borrow `jido_messaging`'s exactly-once message semantics — those belong to Runtime.
2. The two-axis `capabilities/0` (op vs. metadata) and the explicit "metadata-capabilities are not gating" rule (§6.2) are BullX-specific.
3. In-flight outbound state is intentionally **not persisted**. The ScopeWorker queue is in-memory; on a BEAM crash, in-flight deliveries are lost silently and Runtime + Oban re-dispatches. The only durable outbound artefact is a `gateway_dead_letters` row written on terminal failure while ScopeWorker is alive.
