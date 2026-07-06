defmodule Ankole.SystemConfigTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.SystemConfig

  setup do
    allow_cache_database_access()
    clear_app_configure()

    previous_tz = System.get_env("TZ")

    on_exit(fn ->
      restore_tz(previous_tz)
      clear_app_configure()
    end)

    :ok
  end

  test "timezone default follows the process system timezone when no override exists" do
    System.put_env("TZ", "Asia/Shanghai")
    clear_app_configure()

    assert {:ok, "Asia/Shanghai"} = SystemConfig.timezone()
  end

  test "persisted timezone override wins over the system default" do
    System.put_env("TZ", "Asia/Shanghai")
    clear_app_configure()

    assert {:ok, "America/New_York"} = SystemConfig.put_timezone("America/New_York")
    assert {:ok, "America/New_York"} = SystemConfig.timezone()
  end

  test "UTC input is normalized to Etc/UTC" do
    assert {:ok, "Etc/UTC"} = SystemConfig.put_timezone("UTC")
    assert {:ok, "Etc/UTC"} = SystemConfig.timezone()
  end

  defp clear_app_configure do
    Registry.clear_for_test()
    Cache.clear_for_test()
  end

  defp restore_tz(nil), do: System.delete_env("TZ")
  defp restore_tz(timezone), do: System.put_env("TZ", timezone)

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
