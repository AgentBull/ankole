defmodule BullX.Config.CacheSettingsTest do
  use ExUnit.Case, async: false

  alias BullX.Config.CacheSettings

  @redis_url_env "BULLX_CACHE_REDIS_URL"
  @default_ttl_env "BULLX_CACHE_DEFAULT_TTL_SECONDS"
  @pool_size_env "BULLX_CACHE_REDIS_POOL_SIZE"

  setup do
    previous = %{
      @redis_url_env => System.get_env(@redis_url_env),
      @default_ttl_env => System.get_env(@default_ttl_env),
      @pool_size_env => System.get_env(@pool_size_env)
    }

    System.delete_env(@redis_url_env)
    System.delete_env(@default_ttl_env)
    System.delete_env(@pool_size_env)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "redis_url/0" do
    test "returns nil when the env var is unset" do
      assert {:ok, nil} = CacheSettings.redis_url()
    end

    test "returns the URL string when the env var is set" do
      System.put_env(@redis_url_env, "redis://cache.internal:6379")
      assert {:ok, "redis://cache.internal:6379"} = CacheSettings.redis_url()
    end
  end

  describe "default_ttl_seconds/0" do
    test "uses the declaration default when the env var is unset" do
      assert {:ok, 600} = CacheSettings.default_ttl_seconds()
    end

    test "honors a valid env value" do
      System.put_env(@default_ttl_env, "120")
      assert {:ok, 120} = CacheSettings.default_ttl_seconds()
    end

    test "falls back to the default for a non-integer env value" do
      System.put_env(@default_ttl_env, "not_a_number")
      assert {:ok, 600} = CacheSettings.default_ttl_seconds()
    end

    test "falls back to the default for a Zoi-invalid (zero) env value" do
      System.put_env(@default_ttl_env, "0")
      assert {:ok, 600} = CacheSettings.default_ttl_seconds()
    end
  end

  describe "redis_pool_size/0" do
    test "uses the declaration default when the env var is unset" do
      assert {:ok, 10} = CacheSettings.redis_pool_size()
    end

    test "honors a valid env value" do
      System.put_env(@pool_size_env, "25")
      assert {:ok, 25} = CacheSettings.redis_pool_size()
    end

    test "falls back to the default for a non-integer env value" do
      System.put_env(@pool_size_env, "many")
      assert {:ok, 10} = CacheSettings.redis_pool_size()
    end

    test "falls back to the default for a Zoi-invalid (zero) env value" do
      System.put_env(@pool_size_env, "0")
      assert {:ok, 10} = CacheSettings.redis_pool_size()
    end
  end
end
