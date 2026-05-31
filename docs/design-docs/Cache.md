# Cache

`BullX.Cache` is the app-level cache facade. It wraps the Cachetastic default
cache and is bootstrapped through Redis after runtime configuration starts.

The implementation lives in `BullX.Cache` and `BullX.Cache.*`.

## Public API

`BullX.Cache` exposes:

- `get/1`
- `take/1`
- `put_new/3`
- `put/2`
- `put/3`
- `fetch/2`
- `fetch/3`
- `delete/1`
- `clear/0`

Keys are binary strings. Values are arbitrary Elixir terms supported by the
configured Cachetastic backend.

## Configuration

`BullX.Config.CacheSettings` declares:

- `BULLX_CACHE_REDIS_URL`
- `BULLX_CACHE_DEFAULT_TTL_SECONDS`
- `BULLX_CACHE_REDIS_POOL_SIZE`

`BULLX_CACHE_REDIS_URL` is required for the app cache and must be a simple
`redis://host[:port]` URL. The current parser rejects auth, TLS, database path,
and query options.

The default TTL is `600` seconds. The default Redis pool size is `10`.

## Supervision

`BullX.Cache.Bootstrap` runs under `BullX.Config.Supervisor` after
`BullX.Config.Cache`.

The bootstrap verifies Redis connectivity, configures Cachetastic's Redis pool,
starts the default cache, and returns `:ignore`. Returning `:ignore` keeps the
bootstrap out of the supervision tree after setup succeeds.

If Redis is not reachable or the required Redis URL is missing, bootstrap
raises and the config supervisor restarts according to its normal OTP strategy.

## Current Consumers

Current in-tree consumers include direct command dedupe, IMGateway inbound event
dedupe, terminal lifecycle tombstones, AIAgent steering handoff, LLM provider
catalog/model discovery caching, and runtime helpers that need a small shared
cache. MailBox streaming output uses its own Redis-backed stream module and is
documented in [MailBox](MailBox.md); it is not implemented through
`BullX.Cache`.

## Failure Behavior

`BullX.Cache` delegates Cachetastic return values. Most operations return `:ok`,
`{:ok, value}`, `{:error, :not_found}`, or `{:error, reason}` depending on the
underlying operation.

Cache failures are not hidden. Callers that use cache for idempotency or
performance must decide whether to continue, retry, or fail their own operation.
`put_new/3` provides atomic insert-if-absent semantics in Redis mode and falls
back to the configured local cache when Redis-specific calls fail. `take/1`
uses Redis `GETDEL` semantics when available, with a local get/delete fallback.

## Boundaries

The cache layer does not encrypt or decrypt values. Secret handling belongs to
`BullX.Config`.

The cache layer does not provide cross-key transactions, distributed locks,
pattern deletion, or durable work queues.

## Invariants

- PostgreSQL remains the system of record for durable facts.
- Cache values are disposable.
- The cache facade is intentionally small and does not expose backend-specific
  Redis calls.
- Process-local cache state must be reconstructible from configuration and
  Redis.
