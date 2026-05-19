defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: false

  @credentials_key "bullx.plugins.feishu.credentials"
  @sources_key "bullx.plugins.feishu.eventbus_sources"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@credentials_key)
      BullX.Config.Cache.delete_raw(@sources_key)
    end)

    :ok
  end

  test "GET /sessions/new keeps local return_to paths", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new?return_to=/console")

    response = html_response(conn, 200)

    assert response =~ "&quot;component&quot;:&quot;sessions/New&quot;"
    assert response =~ "&quot;return_to&quot;:&quot;/console&quot;"
    assert response =~ "&quot;form_action&quot;:&quot;/sessions/login_auth&quot;"
  end

  test "GET /sessions/new exposes configured OIDC login providers", %{conn: conn} do
    assert :ok =
             BullX.Config.put_many(%{
               @credentials_key =>
                 Jason.encode!(%{
                   "default" => %{
                     "app_id" => "cli_session",
                     "app_secret" => "app_secret"
                   }
                 }),
               @sources_key =>
                 Jason.encode!([
                   %{
                     "id" => "main",
                     "credential_id" => "default",
                     "enabled" => true,
                     "domain" => "feishu",
                     "oidc" => %{"enabled" => true},
                     "start_transport" => false
                   }
                 ])
             })

    conn = get(conn, ~p"/sessions/new?return_to=/console")

    response = html_response(conn, 200)

    assert response =~ "Feishu · main"
    assert response =~ "/sessions/oidc/main"
    assert response =~ "return_to=%2Fconsole"
  end

  test "GET /sessions/new rejects protocol-relative return_to values", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new?return_to=//evil.example/console")

    response = html_response(conn, 200)

    assert response =~ "&quot;component&quot;:&quot;sessions/New&quot;"
    assert response =~ "&quot;return_to&quot;:&quot;/&quot;"
  end

  test "POST /sessions/login_auth redirects invalid codes back to the Inertia page", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> post(~p"/sessions/login_auth", %{"code" => "wrong-code", "return_to" => "/console"})

    assert redirected_to(conn) == ~p"/sessions/new?#{%{return_to: "/console"}}"
    assert Phoenix.Flash.get(conn.assigns.flash, "error") == "login code is invalid or expired"
  end
end
