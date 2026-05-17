defmodule BullX.EventBus.Config do
  @moduledoc false

  alias BullX.Config.CacheSettings

  @event_bus_key :event_bus

  @spec target_session_idle_tick_ms() :: pos_integer()
  def target_session_idle_tick_ms do
    get_positive_integer(:target_session_idle_tick_ms, 5_000)
  end

  @spec target_session_runtime_retention_seconds() :: pos_integer()
  def target_session_runtime_retention_seconds do
    get_positive_integer(:target_session_runtime_retention_seconds, 3_600)
  end

  @spec target_session_cleanup_interval_ms() :: pos_integer() | false
  def target_session_cleanup_interval_ms do
    get_interval(:target_session_cleanup_interval_ms, 60_000)
  end

  @spec stream_retention_seconds() :: pos_integer()
  def stream_retention_seconds do
    get_positive_integer(:stream_retention_seconds, 900)
  end

  @spec max_stream_chunk_bytes() :: pos_integer()
  def max_stream_chunk_bytes do
    get_positive_integer(:max_stream_chunk_bytes, 65_536)
  end

  @spec stream_redis_url() :: {:ok, String.t()} | {:error, term()}
  def stream_redis_url do
    case get_binary(:stream_redis_url) do
      {:ok, url} -> {:ok, url}
      :error -> CacheSettings.redis_url()
    end
  end

  @spec redix_options() :: {:ok, keyword()} | {:error, term()}
  def redix_options do
    with {:ok, url} <- stream_redis_url(),
         {:ok, {host, port}} <- parse_redis_url(url) do
      {:ok, [host: host, port: port, sync_connect: false]}
    end
  end

  defp get_positive_integer(key, default) do
    config = Application.get_env(:bullx, @event_bus_key, [])

    case Keyword.fetch(config, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      {:ok, value} -> raise_invalid_config!(key, value, "must be a positive integer")
      :error -> default
    end
  end

  defp get_interval(key, default) do
    config = Application.get_env(:bullx, @event_bus_key, [])

    case Keyword.fetch(config, key) do
      {:ok, false} -> false
      {:ok, value} when is_integer(value) and value > 0 -> value
      {:ok, value} -> raise_invalid_config!(key, value, "must be false or a positive integer")
      :error -> default
    end
  end

  defp get_binary(key) do
    case Application.get_env(:bullx, @event_bus_key, []) |> Keyword.get(key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp parse_redis_url(url) do
    uri = URI.parse(url)

    case {uri.scheme, uri.host, uri.port} do
      {"redis", host, port} when is_binary(host) -> {:ok, {host, port || 6379}}
      _other -> {:error, :invalid_redis_url}
    end
  end

  defp raise_invalid_config!(key, value, message) do
    raise ArgumentError,
          "invalid :bullx, :event_bus #{inspect(key)} config: #{message}, got: #{inspect(value)}"
  end
end
