defmodule BullX.Cache do
  @moduledoc """
  Application-level cache façade for BullX core and plugins.

  All BullX cache call sites depend on this module instead of
  `Cachetastic` directly. The cache name is pinned to `:default`; backend
  selection (ETS vs Redis) is controlled at boot by
  `BullX.Config.CacheSettings`. See `docs/design-docs/Cache.md`.

  Values are arbitrary Elixir terms. In Redis mode they are serialized
  with `Cachetastic.Serializers.ErlangTerm`, so the same value shapes work
  in both backends.

  `Cachetastic.delete_pattern/1` is intentionally absent: ETS does not
  support pattern deletion, and exposing it would break the
  one-façade-for-both-backends invariant.
  """

  @type key :: String.t()
  @type value :: term()
  @type ttl :: pos_integer() | nil

  @cache_name :default

  @spec get(key()) :: {:ok, value()} | {:error, :not_found} | {:error, term()}
  def get(key) when is_binary(key), do: Cachetastic.get(@cache_name, key)

  @spec put(key(), value()) :: :ok | {:error, term()}
  def put(key, value) when is_binary(key) do
    Cachetastic.put(@cache_name, key, value, nil)
  end

  @spec put(key(), value(), ttl()) :: :ok | {:error, term()}
  def put(key, value, ttl) when is_binary(key) do
    Cachetastic.put(@cache_name, key, value, ttl)
  end

  @spec fetch(key(), (-> value())) :: {:ok, value()} | {:error, term()}
  def fetch(key, fallback_fn) when is_binary(key) and is_function(fallback_fn, 0) do
    Cachetastic.fetch(@cache_name, key, fallback_fn)
  end

  @spec fetch(key(), (-> value()), keyword()) :: {:ok, value()} | {:error, term()}
  def fetch(key, fallback_fn, opts)
      when is_binary(key) and is_function(fallback_fn, 0) and is_list(opts) do
    Cachetastic.fetch(@cache_name, key, fallback_fn, opts)
  end

  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key), do: Cachetastic.delete(@cache_name, key)

  @spec clear() :: :ok | {:error, term()}
  def clear, do: Cachetastic.clear(@cache_name)
end
