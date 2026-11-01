defmodule Ankole.Kernel.ObjectStoreStreamTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel.ObjectStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "ankole-object-stream-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = ObjectStore.open(%{scheme: "fs", root: root})
    %{root: root, store: store}
  end

  test "consumes binary chunks once in the caller and returns committed size and digest", %{
    store: store
  } do
    owner = self()
    chunk = :binary.copy(<<0, 255, 7>>, 1_000_000)

    stream =
      Stream.map(1..7, fn index ->
        assert self() == owner
        send(owner, {:consumed, index})
        chunk
      end)

    assert {:ok, %{size: 21_000_000, sha256: digest}} =
             ObjectStore.write_stream(store, "stream/object", stream)

    assert {:ok, bytes} = ObjectStore.read(store, "stream/object")
    assert byte_size(bytes) == 21_000_000
    assert digest == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    for index <- 1..7, do: assert_received({:consumed, ^index})
    refute_received {:consumed, _}
  end

  test "accepts empty objects and splits oversized source chunks", %{store: store} do
    assert {:ok, %{size: 0, sha256: empty_digest}} =
             ObjectStore.write_stream(store, "empty", ["", ""])

    assert empty_digest == Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
    assert {:ok, ""} = ObjectStore.read(store, "empty")
    chunk = :binary.copy("data", 3_000_000)
    assert {:ok, %{size: 12_000_000}} = ObjectStore.write_stream(store, "large-chunk", [chunk])
    assert {:ok, ^chunk} = ObjectStore.read(store, "large-chunk")
  end

  test "source exceptions propagate and abort instead of replacing the current object", %{
    store: store,
    root: root
  } do
    assert :ok = ObjectStore.write(store, "existing", "original")

    stream =
      Stream.map(1..3, fn
        1 -> :binary.copy("x", 9_000_000)
        2 -> raise "upstream relay failed"
        3 -> flunk("source must halt")
      end)

    assert_raise RuntimeError, "upstream relay failed", fn ->
      ObjectStore.write_stream(store, "existing", stream)
    end

    assert {:ok, "original"} = ObjectStore.read(store, "existing")
    assert_cleanup(root)
  end

  test "invalid source elements abort the upload", %{store: store, root: root} do
    assert_raise ArgumentError, "object store streams must yield binaries", fn ->
      ObjectStore.write_stream(store, "invalid", ["prefix", {:error, :relay_failed}])
    end

    assert_cleanup(root)
    assert {:error, %{"code" => "not_found"}} = ObjectStore.read(store, "invalid")
  end

  test "killing the owner aborts a partially written native upload", %{store: store, root: root} do
    parent = self()

    owner =
      spawn(fn ->
        stream =
          Stream.map(1..2, fn
            1 ->
              :binary.copy("partial", 1_500_000)

            2 ->
              send(parent, :first_chunk_acknowledged)

              receive do
                :continue -> "tail"
              end
          end)

        ObjectStore.write_stream(store, "interrupted", stream)
      end)

    assert_receive :first_chunk_acknowledged, 5_000
    assert File.ls!(Path.join(root, ".tmp")) != []
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert_cleanup(root)
    assert {:error, %{"code" => "not_found"}} = ObjectStore.read(store, "interrupted")
  end

  test "storage open or write failure does not consume the remaining source", %{store: store} do
    assert :ok = ObjectStore.write(store, "parent", "file")
    owner = self()

    stream =
      Stream.map(1..10, fn index ->
        send(owner, {:part, index})
        :binary.copy("x", 8 * 1024 * 1024)
      end)

    assert {:error, %{"code" => "already_exists"}} =
             ObjectStore.write_stream(store, "parent/child", stream)

    refute_received {:part, 10}
    assert {:ok, "file"} = ObjectStore.read(store, "parent")
  end

  defp assert_cleanup(root, attempts \\ 100)
  defp assert_cleanup(root, 0), do: assert(File.ls!(Path.join(root, ".tmp")) == [])

  defp assert_cleanup(root, attempts) do
    if File.ls!(Path.join(root, ".tmp")) != [] do
      Process.sleep(10)
      assert_cleanup(root, attempts - 1)
    end
  end
end
