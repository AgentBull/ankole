defmodule BullX.Cache.Bootstrap do
  @moduledoc """
  Publishes BullX-selected cachetastic configuration into the
  `:cachetastic` application environment and verifies the default cache
  backend can start.

  Runs as a `:transient` child of `BullX.Config.Supervisor`. Returns
  `:ignore` on success so the supervisor does not keep a process alive for
  it; raises on configuration errors so the supervisor restarts and
  startup fails loudly.
  """

  require Logger

  alias BullX.Config.CacheSettings

  @key_prefix "bullx"
  @redis_verify_timeout_ms 1_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    backends = build_backends_config!()
    verify_backends!(backends, opts)
    publish_config!(backends)
    :ok = Cachetastic.ensure_backends_started(:default)
    :ignore
  end

  defp build_backends_config! do
    ttl = CacheSettings.default_ttl_seconds!()
    backends_config!(CacheSettings.redis_url!(), ttl)
  end

  defp publish_config!(backends) do
    Application.put_env(:cachetastic, :backends, backends)
    Application.put_env(:cachetastic, :serializer, Cachetastic.Serializers.ErlangTerm)
    Application.put_env(:cachetastic, :key_prefix, @key_prefix)

    Logger.info(
      "BullX.Cache.Bootstrap configured cachetastic backend=#{primary_backend(backends)} key_prefix=#{@key_prefix}"
    )

    :ok
  end

  defp backends_config!(nil, ttl) do
    [primary: :ets, ets: [ttl: ttl]]
  end

  defp backends_config!(redis_url, ttl) when is_binary(redis_url) do
    {host, port} = parse_redis_url!(redis_url)
    pool_size = CacheSettings.redis_pool_size!()

    [
      primary: :redis_pool,
      redis_pool: [host: host, port: port, pool_size: pool_size, ttl: ttl],
      ets: [ttl: ttl],
      fault_tolerance: [primary: :redis_pool, backup: :ets]
    ]
  end

  defp parse_redis_url!(url) do
    uri = URI.parse(url)
    validate_redis_uri!(url, uri)
    {uri.host, uri.port || 6379}
  end

  defp validate_redis_uri!(url, %URI{} = uri) do
    validate_redis_scheme!(url, uri)
    validate_redis_host!(url, uri)
    validate_redis_port!(url, uri)
    validate_redis_userinfo!(url, uri)
    validate_redis_path!(url, uri)
    validate_redis_query!(url, uri)
  end

  defp validate_redis_scheme!(url, %URI{scheme: scheme}) when scheme != "redis" do
    case scheme do
      "rediss" ->
        raise_url!(
          url,
          "TLS (rediss://) is not supported by cachetastic 1.0.0's RedisPool backend"
        )

      nil ->
        raise_url!(url, "missing scheme; expected redis://host[:port]")

      other ->
        raise_url!(url, "unsupported scheme #{inspect(other)}; expected redis://")
    end
  end

  defp validate_redis_scheme!(_url, %URI{}), do: :ok

  defp validate_redis_host!(url, %URI{host: host}) when host in [nil, ""] do
    raise_url!(url, "missing host")
  end

  defp validate_redis_host!(_url, %URI{}), do: :ok

  defp validate_redis_port!(url, %URI{authority: authority, port: nil})
       when is_binary(authority) do
    if explicit_port?(authority) do
      raise_url!(url, "port must be an integer in 1..65535")
    end
  end

  defp validate_redis_port!(url, %URI{port: port})
       when is_integer(port) and (port < 1 or port > 65_535) do
    raise_url!(url, "port must be in 1..65535")
  end

  defp validate_redis_port!(_url, %URI{}), do: :ok

  defp validate_redis_userinfo!(url, %URI{userinfo: info}) when info not in [nil, ""] do
    raise_url!(
      url,
      "userinfo is not supported; cachetastic 1.0.0's RedisPool backend has no authentication"
    )
  end

  defp validate_redis_userinfo!(_url, %URI{}), do: :ok

  defp validate_redis_path!(url, %URI{path: path}) when path not in [nil, ""] do
    raise_url!(
      url,
      "database/path selection is not supported; cachetastic 1.0.0's RedisPool backend uses Redis DB 0"
    )
  end

  defp validate_redis_path!(_url, %URI{}), do: :ok

  defp validate_redis_query!(url, %URI{query: query}) when query not in [nil, ""] do
    raise_url!(url, "query string is not supported")
  end

  defp validate_redis_query!(_url, %URI{}), do: :ok

  defp explicit_port?(authority) do
    authority
    |> String.split("@", parts: 2)
    |> List.last()
    |> host_part_has_port?()
  end

  defp host_part_has_port?("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [_host, ":" <> _port] -> true
      _other -> false
    end
  end

  defp host_part_has_port?(authority), do: String.contains?(authority, ":")

  defp verify_backends!(backends, opts) do
    if Keyword.get(opts, :verify_redis, true) do
      case Keyword.get(backends, :redis_pool) do
        nil -> :ok
        redis_opts -> verify_redis_connection!(redis_opts)
      end
    else
      :ok
    end
  end

  defp verify_redis_connection!(redis_opts) do
    host = Keyword.fetch!(redis_opts, :host)
    port = Keyword.fetch!(redis_opts, :port)

    opts = [
      host: host,
      port: port,
      sync_connect: true,
      timeout: @redis_verify_timeout_ms
    ]

    case Redix.start_link(opts) do
      {:ok, conn} ->
        Process.unlink(conn)
        verify_redis_ping!(conn, host, port)

      {:error, reason} ->
        raise_redis_connection!(host, port, reason)
    end
  end

  defp verify_redis_ping!(conn, host, port) do
    try do
      case Redix.command(conn, ["PING"], timeout: @redis_verify_timeout_ms) do
        {:ok, "PONG"} -> :ok
        {:error, reason} -> raise_redis_connection!(host, port, reason)
        other -> raise_redis_connection!(host, port, other)
      end
    catch
      :exit, reason ->
        raise_redis_connection!(host, port, {:redix_exit, reason})
    after
      stop_redis_connection(conn)
    end
  end

  defp stop_redis_connection(conn) do
    if Process.alive?(conn) do
      Redix.stop(conn, @redis_verify_timeout_ms)
    end
  catch
    :exit, _reason -> :ok
  end

  defp raise_redis_connection!(host, port, reason) do
    raise RuntimeError,
          "BULLX_CACHE_REDIS_URL selected Redis, but Redis backend could not be verified at #{host}:#{port}: #{inspect(reason)}"
  end

  defp raise_url!(url, reason) do
    raise ArgumentError,
          "BULLX_CACHE_REDIS_URL=#{inspect(url)} is invalid: #{reason}"
  end

  defp primary_backend(config) do
    case Keyword.get(config, :fault_tolerance) do
      nil -> Keyword.get(config, :primary, :ets)
      ft -> Keyword.fetch!(ft, :primary)
    end
  end
end
