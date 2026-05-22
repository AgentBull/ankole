defmodule BullX.Config.PluginsTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  @db_key "bullx.enabled_plugins"
  @env_key "BULLX_ENABLED_PLUGINS"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    previous_app_env = Application.get_env(:bullx, :enabled_plugins)
    previous_internal_plugin_apps = Application.get_env(:bullx, :internal_plugin_apps)

    on_exit(fn ->
      System.delete_env(@env_key)
      BullX.Config.Cache.delete_raw(@db_key)
      restore_app_env(previous_app_env)
      restore_internal_plugin_apps(previous_internal_plugin_apps)
    end)

    :ok
  end

  test "enabled_plugins resolves JSON arrays from PostgreSQL" do
    Application.put_env(:bullx, :internal_plugin_apps, [:yuma_serp])
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: @db_key, value: ~s(["local","github"])})
    BullX.Config.Cache.refresh(@db_key)

    assert BullX.Config.Plugins.enabled_plugins!() == ["local", "github", "yuma_serp"]
  end

  test "enabled_plugins resolves native lists from application config" do
    Application.put_env(:bullx, :internal_plugin_apps, [:yuma_serp])
    Application.put_env(:bullx, :enabled_plugins, ["local"])

    assert BullX.Config.Plugins.enabled_plugins!() == ["local", "yuma_serp"]
  end

  test "enabled_plugins defaults to Feishu, Telegram, and internal plugins" do
    Application.delete_env(:bullx, :enabled_plugins)
    Application.put_env(:bullx, :internal_plugin_apps, [:yuma_serp, :other_internal])

    assert BullX.Config.Plugins.enabled_plugins!() == [
             "feishu",
             "bullx_telegram",
             "yuma_serp",
             "other_internal"
           ]
  end

  test "invalid JSON falls through to the next source" do
    Application.put_env(:bullx, :internal_plugin_apps, [:yuma_serp])
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: @db_key, value: "not-json"})
    BullX.Config.Cache.refresh(@db_key)
    System.put_env(@env_key, ~s(["env"]))

    log =
      capture_log(fn ->
        assert BullX.Config.Plugins.enabled_plugins!() == ["env", "yuma_serp"]
      end)

    assert log =~ ~s(Cannot cast "not-json")
  end

  defp restore_app_env(nil), do: Application.delete_env(:bullx, :enabled_plugins)
  defp restore_app_env(value), do: Application.put_env(:bullx, :enabled_plugins, value)

  defp restore_internal_plugin_apps(nil),
    do: Application.delete_env(:bullx, :internal_plugin_apps)

  defp restore_internal_plugin_apps(value),
    do: Application.put_env(:bullx, :internal_plugin_apps, value)
end
