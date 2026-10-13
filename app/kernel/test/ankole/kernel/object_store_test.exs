defmodule Ankole.Kernel.ObjectStoreTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel.ObjectStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "ankole-object-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = ObjectStore.open(%{scheme: "fs", root: root})
    %{root: root, store: store}
  end

  test "writes, reads, and deletes an object", %{root: root, store: store} do
    assert :ok = ObjectStore.write(store, "blobs/a", <<0, 1, 2, "bytes">>)
    assert {:ok, <<0, 1, 2, "bytes">>} = ObjectStore.read(store, "blobs/a")
    assert File.exists?(Path.join(root, "blobs/a"))

    assert :ok = ObjectStore.delete(store, "blobs/a")
    assert :ok = ObjectStore.delete(store, "blobs/a")
    assert {:error, %{"code" => "not_found"}} = ObjectStore.read(store, "blobs/a")
  end

  test "moves objects through local files", %{root: root, store: store} do
    source = Path.join(root, "source.bin")
    target = Path.join(root, "target.bin")
    payload = :crypto.strong_rand_bytes(70_000)
    File.mkdir_p!(root)
    File.write!(source, payload)

    assert :ok = ObjectStore.write_from_file(store, "blobs/file", source)
    assert :ok = ObjectStore.read_to_file(store, "blobs/file", target)
    assert File.read!(target) == payload
  end

  @tag :network
  test "S3 errors pass through the shared TLS provider" do
    {:ok, store} =
      ObjectStore.open(%{
        scheme: "s3",
        bucket: "ankole-tls-probe-#{System.unique_integer([:positive])}",
        region: "us-east-1",
        endpoint: "https://s3.us-east-1.amazonaws.com",
        access_key_id: "AKIAANKOLETLSPROBE00",
        secret_access_key: "invalid"
      })

    assert {:error, %{"code" => code}} = ObjectStore.read(store, "probe")
    assert code in ["permission_denied", "not_found"]
  end

  test "rejects an invalid spec" do
    assert {:error, %{"code" => "invalid_spec"}} = ObjectStore.open(%{scheme: "unknown"})
  end
end
