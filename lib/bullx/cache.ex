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

  @spec take(key()) :: {:ok, value()} | {:error, :not_found} | {:error, term()}
  def take(key) when is_binary(key) do
    case redis_take(key) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> local_take(key)
    end
  end

  @spec put_new(key(), value(), pos_integer()) :: :inserted | :exists | {:error, term()}
  def put_new(key, value, ttl) when is_binary(key) and is_integer(ttl) and ttl > 0 do
    case redis_put_new(key, value, ttl) do
      :inserted -> :inserted
      :exists -> :exists
      {:error, _reason} -> local_put_new(key, value, ttl)
    end
  end

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

  defp redis_put_new(key, value, ttl) do
    with {:ok, encoded} <- Cachetastic.Serializer.encode(value),
         {:ok, result} <-
           BullX.Redis.command(["SET", prefixed_key(key), encoded, "EX", ttl, "NX"]) do
      case result do
        "OK" -> :inserted
        nil -> :exists
      end
    end
  end

  defp redis_take(key) do
    with {:ok, encoded} <- BullX.Redis.command(["GETDEL", prefixed_key(key)]) do
      case encoded do
        nil -> {:error, :not_found}
        value -> Cachetastic.Serializer.decode(value)
      end
    end
  end

  defp local_put_new(key, value, ttl) do
    case get(key) do
      {:ok, _value} ->
        :exists

      {:error, :not_found} ->
        case put(key, value, ttl) do
          :ok -> :inserted
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp local_take(key) do
    with {:ok, value} <- get(key),
         :ok <- delete(key) do
      {:ok, value}
    end
  end

  defp prefixed_key(key) do
    case Application.get_env(:cachetastic, :key_prefix) do
      nil -> key
      prefix -> "#{prefix}:#{key}"
    end
  end
end
