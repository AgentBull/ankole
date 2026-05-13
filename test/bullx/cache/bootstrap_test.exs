defmodule BullX.Cache.BootstrapTest do
  use ExUnit.Case, async: false

  alias BullX.Cache.Bootstrap

  @redis_url_env "BULLX_CACHE_REDIS_URL"
  @default_ttl_env "BULLX_CACHE_DEFAULT_TTL_SECONDS"
  @pool_size_env "BULLX_CACHE_REDIS_POOL_SIZE"

  setup do
    previous_env = %{
      @redis_url_env => System.get_env(@redis_url_env),
      @default_ttl_env => System.get_env(@default_ttl_env),
      @pool_size_env => System.get_env(@pool_size_env)
    }

    previous_app_env = %{
      backends: Application.get_env(:cachetastic, :backends),
      serializer: Application.get_env(:cachetastic, :serializer),
      key_prefix: Application.get_env(:cachetastic, :key_prefix)
    }

    System.delete_env(@redis_url_env)
    System.delete_env(@default_ttl_env)
    System.delete_env(@pool_size_env)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Enum.each(previous_app_env, fn
        {key, nil} -> Application.delete_env(:cachetastic, key)
        {key, value} -> Application.put_env(:cachetastic, key, value)
      end)
    end)

    :ok
  end

  describe "ETS mode" do
    test "publishes ETS-only backend config when redis_url is unset" do
      assert :ignore = Bootstrap.start_link([])

      backends = Application.get_env(:cachetastic, :backends)
      assert Keyword.get(backends, :primary) == :ets
      assert Keyword.get(backends, :ets) == [ttl: 600]
      refute Keyword.has_key?(backends, :redis_pool)
      refute Keyword.has_key?(backends, :fault_tolerance)

      assert Application.get_env(:cachetastic, :serializer) ==
               Cachetastic.Serializers.ErlangTerm

      assert Application.get_env(:cachetastic, :key_prefix) == "bullx"
    end

    test "uses the configured default TTL" do
      System.put_env(@default_ttl_env, "30")
      assert :ignore = Bootstrap.start_link([])

      backends = Application.get_env(:cachetastic, :backends)
      assert Keyword.get(backends, :ets) == [ttl: 30]
    end
  end

  describe "Redis mode" do
    test "publishes Redis backend config with fault-tolerance fallback to ETS" do
      System.put_env(@redis_url_env, "redis://cache.internal:6380")
      System.put_env(@pool_size_env, "20")
      System.put_env(@default_ttl_env, "120")

      assert :ignore = Bootstrap.start_link(verify_redis: false)

      backends = Application.get_env(:cachetastic, :backends)
      assert Keyword.get(backends, :primary) == :redis_pool

      assert Keyword.get(backends, :redis_pool) ==
               [host: "cache.internal", port: 6380, pool_size: 20, ttl: 120]

      assert Keyword.get(backends, :ets) == [ttl: 120]

      assert Keyword.get(backends, :fault_tolerance) ==
               [primary: :redis_pool, backup: :ets]
    end

    test "defaults the port to 6379 when omitted" do
      System.put_env(@redis_url_env, "redis://cache.internal")

      assert :ignore = Bootstrap.start_link(verify_redis: false)

      backends = Application.get_env(:cachetastic, :backends)
      redis_pool_opts = Keyword.get(backends, :redis_pool)
      assert Keyword.get(redis_pool_opts, :port) == 6379
    end
  end

  describe "invalid Redis URLs" do
    test "rejects a missing scheme with a descriptive message" do
      System.put_env(@redis_url_env, "not-a-url")

      assert_raise ArgumentError, ~r/missing scheme/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects rediss:// (TLS) as unsupported" do
      System.put_env(@redis_url_env, "rediss://cache.internal:6379")

      assert_raise ArgumentError, ~r/TLS/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects unsupported schemes" do
      System.put_env(@redis_url_env, "http://cache.internal:6379")

      assert_raise ArgumentError, ~r/unsupported scheme/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects userinfo (no authentication support)" do
      System.put_env(@redis_url_env, "redis://user:pass@cache.internal:6379")

      assert_raise ArgumentError, ~r/userinfo is not supported/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects path / database selection" do
      System.put_env(@redis_url_env, "redis://cache.internal:6379/0")

      assert_raise ArgumentError, ~r/database\/path/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects empty path / database selection" do
      System.put_env(@redis_url_env, "redis://cache.internal:6379/")

      assert_raise ArgumentError, ~r/database\/path/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects URLs with a query string" do
      System.put_env(@redis_url_env, "redis://cache.internal:6379?timeout=5")

      assert_raise ArgumentError, ~r/query string/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects URLs missing a host" do
      System.put_env(@redis_url_env, "redis://")

      assert_raise ArgumentError, ~r/missing host/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects a non-integer explicit port" do
      System.put_env(@redis_url_env, "redis://cache.internal:abc")

      assert_raise ArgumentError, ~r/port must be an integer/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects a trailing colon without a port" do
      System.put_env(@redis_url_env, "redis://cache.internal:")

      assert_raise ArgumentError, ~r/port must be an integer/, fn ->
        Bootstrap.start_link([])
      end
    end

    test "rejects an out-of-range port" do
      System.put_env(@redis_url_env, "redis://cache.internal:99999")

      assert_raise ArgumentError, ~r/port must be in 1\.\.65535/, fn ->
        Bootstrap.start_link([])
      end
    end
  end

  describe "Redis verification" do
    test "fails startup when Redis is selected but cannot answer PING" do
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen_socket)
      parent = self()

      acceptor =
        spawn_link(fn ->
          case :gen_tcp.accept(listen_socket, 2_000) do
            {:ok, socket} ->
              :gen_tcp.close(socket)
              send(parent, :redis_probe_accepted)

            other ->
              send(parent, {:redis_probe_accept_failed, other})
          end

          :gen_tcp.close(listen_socket)
        end)

      System.put_env(@redis_url_env, "redis://127.0.0.1:#{port}")

      assert_raise RuntimeError, ~r/Redis backend could not be verified/, fn ->
        Bootstrap.start_link([])
      end

      assert_receive :redis_probe_accepted, 2_000
      refute Process.alive?(acceptor)
    end
  end
end
