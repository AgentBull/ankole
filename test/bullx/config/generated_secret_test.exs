defmodule BullX.Config.GeneratedSecretTest do
  use BullX.DataCase, async: false

  alias BullX.Config.GeneratedSecret

  @db_key "bullx.test_generated_secret"
  @env_key "BULLX_TEST_GENERATED_SECRET"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      System.delete_env(@env_key)
      BullX.Config.Cache.delete_raw(@db_key)
    end)

    :ok
  end

  test "generate/1 returns a URL-safe secret with at least 256 bits of default entropy" do
    secret = GeneratedSecret.generate()

    assert is_binary(secret)
    assert String.length(secret) >= 43
    assert secret =~ ~r/\A[A-Za-z0-9_-]+\z/
  end

  test "generate/1 rejects entropy below the default security floor" do
    assert_raise ArgumentError, fn ->
      GeneratedSecret.generate(entropy_bits: 128)
    end
  end

  test "cast/1 accepts generated values" do
    secret = GeneratedSecret.generate()

    assert {:ok, ^secret} = GeneratedSecret.cast(secret)
  end

  test "cast/1 rejects empty malformed and too-short values" do
    assert :error = GeneratedSecret.cast("")
    assert :error = GeneratedSecret.cast("short")
    assert :error = GeneratedSecret.cast(String.duplicate("a", 42))
    assert :error = GeneratedSecret.cast(String.duplicate("a", 43) <> ".")
    assert :error = GeneratedSecret.cast(nil)
  end

  test "type: :generated_secret is usable from the BullX config DSL" do
    secret = GeneratedSecret.generate()
    System.put_env(@env_key, secret)

    assert BullX.Config.TestSettings.test_generated_secret!() == secret
  end

  test "malformed generated secret env value falls back to default" do
    System.put_env(@env_key, "short")

    assert BullX.Config.TestSettings.test_generated_secret!() == nil
  end

  test "generated secret declarations still use secret storage" do
    secret = GeneratedSecret.generate()

    assert :ok = BullX.Config.put(@db_key, secret)

    row = BullX.Repo.get!(BullX.Config.AppConfig, @db_key)
    assert row.type == :secret
    assert row.value != secret
    assert {:ok, ^secret} = BullX.Config.Cache.get_raw(@db_key)
  end
end
