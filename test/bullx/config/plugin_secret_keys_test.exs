defmodule BullX.Config.PluginSecretKeysTest do
  use BullX.DataCase, async: false

  @plugin_key "bullx.plugins.test_plugin.secret"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    previous_plugin_apps = Application.get_env(:bullx, :plugin_apps)

    Application.put_env(:bullx, :plugin_apps, [:test_plugin])
    BullX.Config.SecretKeys.reset()

    on_exit(fn ->
      restore_plugin_apps(previous_plugin_apps)
      BullX.Config.SecretKeys.reset()
      BullX.Config.Cache.delete_raw(@plugin_key)
    end)

    :ok
  end

  test "plugin-declared secret keys are encrypted before the plugin is enabled" do
    assert :ok = BullX.Config.Writer.put(@plugin_key, "plugin-secret")

    row = BullX.Repo.get!(BullX.Config.AppConfig, @plugin_key)
    assert row.type == :secret
    assert row.value != "plugin-secret"
    assert {:ok, "plugin-secret"} = BullX.Config.Cache.get_raw(@plugin_key)
  end

  defp restore_plugin_apps(nil), do: Application.delete_env(:bullx, :plugin_apps)
  defp restore_plugin_apps(value), do: Application.put_env(:bullx, :plugin_apps, value)
end
