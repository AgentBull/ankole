defmodule BullX.Config.WriterTest do
  use BullX.DataCase, async: false

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    on_exit(fn -> BullX.Config.Cache.refresh_all() end)
    :ok
  end

  test "put/2 upserts into database and populates ETS" do
    assert :ok = BullX.Config.Writer.put("writer.key1", "val1")

    assert %BullX.Config.AppConfig{value: "val1", type: :plain} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.key1")

    assert {:ok, "val1"} = BullX.Config.Cache.get_raw("writer.key1")
  end

  test "put/2 updates an existing row on conflict" do
    assert :ok = BullX.Config.Writer.put("writer.key2", "first")
    assert :ok = BullX.Config.Writer.put("writer.key2", "second")

    assert %BullX.Config.AppConfig{value: "second"} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.key2")

    assert {:ok, "second"} = BullX.Config.Cache.get_raw("writer.key2")
  end

  test "delete/1 removes the row and clears ETS" do
    BullX.Config.Writer.put("writer.del", "to_delete")
    assert {:ok, "to_delete"} = BullX.Config.Cache.get_raw("writer.del")

    assert :ok = BullX.Config.Writer.delete("writer.del")

    assert is_nil(BullX.Repo.get(BullX.Config.AppConfig, "writer.del"))
    assert :error = BullX.Config.Cache.get_raw("writer.del")
  end

  test "delete/1 is a no-op for nonexistent keys" do
    assert :ok = BullX.Config.Writer.delete("writer.nonexistent")
  end

  test "put/2 encrypts and stores as :secret for keys declared with secret: true" do
    assert :ok = BullX.Config.Writer.put("bullx.test_secret", "my-sensitive-value")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "bullx.test_secret")
    assert row.type == :secret
    assert row.value != "my-sensitive-value"
    assert String.contains?(row.value, ".")

    assert {:ok, "my-sensitive-value"} = BullX.Config.Cache.get_raw("bullx.test_secret")
  end

  test "put/2 re-encrypts on overwrite of a secret key" do
    assert :ok = BullX.Config.Writer.put("bullx.test_secret", "first")
    assert :ok = BullX.Config.Writer.put("bullx.test_secret", "second")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "bullx.test_secret")
    assert row.type == :secret
    assert {:ok, "second"} = BullX.Config.Cache.get_raw("bullx.test_secret")
  end

  test "put_many/1 upserts plain and secret keys in one committed batch" do
    assert :ok =
             BullX.Config.Writer.put_many(%{
               "writer.batch_plain" => "plain-value",
               "bullx.test_secret" => "secret-value"
             })

    assert %BullX.Config.AppConfig{value: "plain-value", type: :plain} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.batch_plain")

    secret = BullX.Repo.get!(BullX.Config.AppConfig, "bullx.test_secret")
    assert secret.type == :secret
    assert secret.value != "secret-value"

    assert {:ok, "plain-value"} = BullX.Config.Cache.get_raw("writer.batch_plain")
    assert {:ok, "secret-value"} = BullX.Config.Cache.get_raw("bullx.test_secret")
  end

  test "put_many/1 updates existing rows and lets the last duplicate entry win" do
    assert :ok = BullX.Config.Writer.put("writer.batch_existing", "old")

    assert :ok =
             BullX.Config.Writer.put_many([
               {"writer.batch_existing", "new"},
               {"writer.batch_duplicate", "first"},
               {"writer.batch_duplicate", "second"}
             ])

    assert %BullX.Config.AppConfig{value: "new"} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.batch_existing")

    assert %BullX.Config.AppConfig{value: "second"} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.batch_duplicate")
  end

  test "put_many/1 rejects invalid entries before writing any row" do
    assert {:error, :invalid_entries} =
             BullX.Config.Writer.put_many([
               {"writer.batch_valid_before_invalid", "value"},
               {:not_a_binary_key, "value"}
             ])

    refute BullX.Repo.get(BullX.Config.AppConfig, "writer.batch_valid_before_invalid")
  end
end
