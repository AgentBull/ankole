defmodule AnkoleWeb.SpaControllerTest do
  use AnkoleWeb.ConnCase

  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Cache.clear_for_test()
    :ok = SetupConfig.delete_bootstrap_activation_code()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok
  end

  test "GET / redirects to setup until setup completes", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / redirects to sessions after setup completes", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/sessions/new"
  end

  test "GET /setup serves setup before completion", %{conn: conn} do
    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/setup.tsx)
  end

  test "GET /setup exposes the current Ankole version to the SPA", %{conn: conn} do
    previous_version = System.get_env("ANKOLE_VERSION")
    System.put_env("ANKOLE_VERSION", "v26.07.8")
    on_exit(fn -> restore_env("ANKOLE_VERSION", previous_version) end)

    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ ~s(<meta name="ankole-version" content="v26.07.8">)
  end

  test "GET /setup redirects home after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /sessions/new serves auth after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/sessions/new")

    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/auth.tsx)
  end

  test "GET /console redirects anonymous users to auth after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/console/settings")

    assert redirected_to(conn) == ~p"/sessions/new?return_to=%2Fconsole%2Fsettings"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
