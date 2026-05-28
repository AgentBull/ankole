defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: false

  @sources_key "bullx.plugins.feishu.im_gateway_sources"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@sources_key)
    end)

    :ok
  end

  test "GET /sessions/new keeps local return_to paths", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new?return_to=/console")

    response = html_response(conn, 200)

    assert response =~ "&quot;return_to&quot;:&quot;/console&quot;"
    assert response =~ "&quot;form_action&quot;:&quot;/sessions/login_auth&quot;"
  end

  test "GET /sessions/new exposes configured OIDC login providers", %{conn: conn} do
    assert :ok = configure_oidc_source("main")

    conn = get(conn, ~p"/sessions/new?return_to=/console")

    response = html_response(conn, 200)

    assert response =~ "Feishu · main"
    assert response =~ "/sessions/oidc/main"
    assert response =~ "return_to=%2Fconsole"
  end

  test "GET /sessions/oidc redirects non-canonical origins before OIDC start", %{conn: conn} do
    assert :ok = configure_oidc_source("main")

    conn =
      %{conn | host: "127.0.0.1", port: 4000}
      |> get(~p"/sessions/oidc/main?return_to=/console")

    assert redirected_to(conn) == "http://localhost:4000/sessions/oidc/main?return_to=%2Fconsole"
  end

  test "GET /sessions/oidc starts OIDC from the canonical origin", %{conn: conn} do
    assert :ok = configure_oidc_source("main")

    conn =
      %{conn | host: "localhost", port: 4000}
      |> get(~p"/sessions/oidc/main?return_to=/console")

    location = redirected_to(conn)
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert location =~ "https://accounts.feishu.cn/open-apis/authen/v1/authorize?"
    assert query["redirect_uri"] == "http://localhost:4000/sessions/oidc/main/callback"
    assert query["state"] != ""
  end

  test "GET /sessions/oidc callback reports missing state as login state failure", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> get(~p"/sessions/oidc/main/callback?state=missing&code=code")

    assert response(conn, 401) == "login state is invalid or expired"
  end

  test "GET /sessions/new rejects protocol-relative return_to values", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new?return_to=//evil.example/console")

    response = html_response(conn, 200)

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

  defp configure_oidc_source(id) do
    BullX.Config.put(
      @sources_key,
      Jason.encode!([
        %{
          "id" => id,
          "app_id" => "cli_session",
          "app_secret" => "app_secret",
          "enabled" => true,
          "domain" => "feishu",
          "oidc" => %{"enabled" => true},
          "start_transport" => false
        }
      ])
    )
  end
end
