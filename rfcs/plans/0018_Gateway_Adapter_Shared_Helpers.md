# RFC 0018: Gateway Adapter Shared Helpers

**Status**: Implementation plan
**Author**: OpenAI Codex
**Created**: 2026-05-11
**Depends on**: RFC 0002, RFC 0003, RFC 0009, RFC 0015, RFC 0016

## 1. Scope

Reduce accidental duplication across the Feishu, Discord, and Telegram Gateway
adapters where the duplicated code represents a stable Gateway-owned contract.

This plan covers:

- Adapter-local TTL cache storage mechanics.
- Adapter error map construction and string-key normalization.
- Outbound delivery telemetry span metadata and result metadata.

The adapter modules still own platform-specific behavior:

- Error classification from SDK/API failures.
- Direct-command parsing, account-gate replies, and duplicate result shape.
- Delivery rendering, platform send/edit APIs, reply fallback, chunking, and
  streaming behavior.

## 2. Non-Goals

- Do not introduce `BullXGateway.DirectCommandRunner`.
- Do not introduce `BullXGateway.Delivery.Pipeline`.
- Do not merge Feishu, Discord, and Telegram direct-command modules.
- Do not move adapter-specific error classification into Gateway core.
- Do not change Gateway signal, delivery, retry, DLQ, or supervision contracts.
- Do not add dependencies.

## 3. Cleanup Plan

### 3.1 What can be deleted

Delete duplicated private helpers from adapter modules when they only implement
Gateway-owned mechanics:

- `base/3`, `stringify/1`, nested `stringify_value/1`, and nil-skipping map
  put helpers from adapter error modules.
- `telemetry_meta/1` and `telemetry_result/1` from adapter delivery modules.
- ETS TTL freshness checks from adapter cache modules.

Do not delete adapter-local cache wrapper modules. They are the namespaced
surface for platform-specific cache entries such as Feishu message context,
Feishu card-action dedupe, Discord thread ownership, and direct-command result
dedupe.

### 3.2 Existing utilities and patterns to reuse

- `BullXGateway.Adapter` remains the adapter public contract.
- `BullXGateway.Delivery` remains the outbound carrier and is the right home
  for shared delivery telemetry span construction.
- `BullXGateway.Delivery.Outcome` remains the success/failure projection shape.
- Adapter cache state remains process-local ETS owned by adapter channel
  processes.

### 3.3 Code paths changing

- Add `BullXGateway.AdapterCache` for private ETS TTL put/fetch behavior.
- Add `BullXGateway.AdapterError` for string-keyed adapter error maps.
- Add `BullXGateway.Delivery.telemetry_span/3` for delivery telemetry spans.
- Update `BullXFeishu.Cache`, `BullXDiscord.Cache`, and `BullXTelegram.Cache`
  to delegate storage mechanics to `BullXGateway.AdapterCache`.
- Update `BullXFeishu.Error`, `BullXDiscord.Error`, and `BullXTelegram.Error`
  to delegate shared error map construction to `BullXGateway.AdapterError`.
- Update `BullXFeishu.Delivery`, `BullXDiscord.Delivery`, and
  `BullXTelegram.Delivery` to use the shared delivery telemetry span.

### 3.4 Invariants

- Gateway core remains transport-agnostic.
- No OTP failure boundary changes. The adapter supervision tree is unchanged.
- Adapter process state remains ephemeral and reconstructible.
- Adapter-local commands still do not enter the Runtime signal stream.
- Adapter-specific command syntax and duplicate response shapes remain local.
- Adapter success paths still return only `{:ok, %Outcome{status: :sent |
  :degraded, error: nil}}`.
- Adapter failures still return `{:error, error_map}` with string-keyed,
  JSON-neutral maps.
- Existing telemetry event names remain `[:bullx, adapter, :delivery]`.

## 4. Deliberate Duplication

Direct-command modules retain some visible duplication by design. The common
command names are not enough to justify a Gateway-level runner because the
platform behavior has already diverged:

- Telegram parses bot-qualified commands and returns duplicate webhook results
  as JSON-shaped maps.
- Discord supports native interaction replies with ephemeral flags and safe
  allowed-mentions defaults.
- Feishu, Discord, and Telegram each use different DM/private-chat predicates
  and reply target fields.

Future work may extract a small pure slash-command parser if another adapter
proves the same parsing contract. It should not extract command execution,
reply delivery, or account-gate behavior without repeated pressure.

## 5. Verification

Run:

```bash
mix test test/bullx_gateway/adapter_cache_test.exs test/bullx_gateway/adapter_error_test.exs test/bullx_gateway/delivery_telemetry_test.exs
mix test test/bullx_discord test/bullx_feishu test/bullx_telegram
bun precommit
```
