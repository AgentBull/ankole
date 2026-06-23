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

  test "GET / redirects to auth after setup completes", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/auth"
  end

  test "GET /setup serves setup before completion", %{conn: conn} do
    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ ~s(http://assets.test/@react-refresh)
    assert html_response(conn, 200) =~ ~s(__vite_plugin_react_preamble_installed__)
    assert html_response(conn, 200) =~ ~s(http://assets.test/@vite/client)
    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/setup.tsx)
  end

  test "GET /setup redirects home after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /auth redirects to setup before completion", %{conn: conn} do
    conn = get(conn, ~p"/auth")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET /auth serves auth after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/auth")

    assert html_response(conn, 200) =~ ~s(http://assets.test/@react-refresh)
    assert html_response(conn, 200) =~ ~s(__vite_plugin_react_preamble_installed__)
    assert html_response(conn, 200) =~ ~s(http://assets.test/@vite/client)
    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/auth.tsx)
  end

  test "GET /console redirects anonymous users to auth after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/console/settings")

    assert redirected_to(conn) == ~p"/auth"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
