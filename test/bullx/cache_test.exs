defmodule BullX.CacheTest do
  use ExUnit.Case, async: false

  setup do
    BullX.Cache.clear()
    on_exit(fn -> BullX.Cache.clear() end)
    :ok
  end

  describe "put/get" do
    test "round-trips a binary value" do
      key = unique_key("rt-binary")

      assert :ok = BullX.Cache.put(key, "hello")
      assert {:ok, "hello"} = BullX.Cache.get(key)
    end

    test "round-trips an arbitrary Elixir term via the Erlang term serializer" do
      key = unique_key("rt-term")
      value = %{users: [1, 2, 3], meta: {:ok, "fresh"}}

      assert :ok = BullX.Cache.put(key, value)
      assert {:ok, ^value} = BullX.Cache.get(key)
    end

    test "missing keys return {:error, :not_found}" do
      assert {:error, :not_found} = BullX.Cache.get(unique_key("absent"))
    end
  end

  describe "put/3 with TTL" do
    test "respects an explicit TTL" do
      key = unique_key("ttl")

      assert :ok = BullX.Cache.put(key, "transient", 1)
      assert {:ok, "transient"} = BullX.Cache.get(key)

      Process.sleep(1_100)

      assert {:error, :not_found} = BullX.Cache.get(key)
    end
  end

  describe "fetch/2" do
    test "calls the fallback on miss and caches the result" do
      key = unique_key("fetch-miss")
      counter = :counters.new(1, [:atomics])

      fallback = fn ->
        :counters.add(counter, 1, 1)
        "computed"
      end

      assert {:ok, "computed"} = BullX.Cache.fetch(key, fallback)
      assert {:ok, "computed"} = BullX.Cache.fetch(key, fallback)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "delete/1" do
    test "removes a previously written key" do
      key = unique_key("delete")

      assert :ok = BullX.Cache.put(key, "bye")
      assert {:ok, "bye"} = BullX.Cache.get(key)
      assert :ok = BullX.Cache.delete(key)
      assert {:error, :not_found} = BullX.Cache.get(key)
    end
  end

  describe "clear/0" do
    test "removes every cached entry" do
      key_a = unique_key("clear-a")
      key_b = unique_key("clear-b")

      assert :ok = BullX.Cache.put(key_a, "a")
      assert :ok = BullX.Cache.put(key_b, "b")
      assert :ok = BullX.Cache.clear()

      assert {:error, :not_found} = BullX.Cache.get(key_a)
      assert {:error, :not_found} = BullX.Cache.get(key_b)
    end
  end

  defp unique_key(prefix) do
    suffix = System.unique_integer([:positive])
    "test:#{prefix}:#{suffix}"
  end
end
