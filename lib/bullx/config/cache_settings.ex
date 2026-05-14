defmodule BullX.Config.CacheSettings do
  @moduledoc """
  Runtime declarations for the BullX application cache.

  Settings resolve through `BullX.Config.SystemBinding` only so cache
  availability cannot depend on a working `app_configs` read path. See
  `docs/design-docs/Cache.md` for the full design and the rationale for
  restricting the binding pipeline.
  """

  use BullX.Config

  @envdoc """
  Required Redis endpoint for BullX's application cache. Shape:
  `redis://host[:port]`. URLs with userinfo, a non-empty path, or the
  `rediss://` scheme are rejected during cache bootstrap because cachetastic
  1.0.0's RedisPool backend does not support authentication, TLS, or database
  selection.
  """
  bullx_env(:redis_url,
    key: [:cache, :redis_url],
    type: :binary,
    required: true,
    binding_order: [BullX.Config.SystemBinding],
    binding_skip: [:system, :config]
  )

  @envdoc """
  Backend-level fallback TTL in seconds when callers do not pass one.
  """
  bullx_env(:default_ttl_seconds,
    key: [:cache, :default_ttl_seconds],
    type: :integer,
    default: 600,
    binding_order: [BullX.Config.SystemBinding],
    binding_skip: [:system, :config],
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc """
  Redis connection pool size.
  """
  bullx_env(:redis_pool_size,
    key: [:cache, :redis_pool_size],
    type: :integer,
    default: 10,
    binding_order: [BullX.Config.SystemBinding],
    binding_skip: [:system, :config],
    zoi: Zoi.integer(gte: 1)
  )
end
