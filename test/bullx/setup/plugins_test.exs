defmodule BullX.Setup.PluginsTest do
  use BullX.DataCase, async: false

  alias BullX.Config.AppConfig
  alias BullX.Repo
  alias BullX.Setup.Plugins

  @enabled_plugins_key "bullx.enabled_plugins"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@enabled_plugins_key)
    end)

    :ok
  end

  test "saving known plugin ids writes the desired JSON list through BullX.Config" do
    [first_id, second_id | _rest] = Enum.map(BullX.Plugins.plugins(), & &1.id)

    assert :ok = Plugins.save_enabled([first_id, second_id, first_id])

    stored = Repo.get!(AppConfig, @enabled_plugins_key)
    assert Jason.decode!(stored.value) == [first_id, second_id]
  end

  test "unknown plugin ids are rejected without writing plugin enablement config" do
    assert {:error, %{field: "plugins", details: ["missing_plugin"]}} =
             Plugins.save_enabled(["feishu", "missing_plugin"])

    refute Repo.get(AppConfig, @enabled_plugins_key)
  end
end
