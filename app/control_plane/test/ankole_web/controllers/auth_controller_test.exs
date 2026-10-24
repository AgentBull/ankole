defmodule AnkoleWeb.AuthControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.IdentityProviders
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "return_to keeps local paths and rejects protocol-relative or backslash-relative paths" do
    assert WebSession.safe_return_to("/site-admin-console") == "/site-admin-console"
    assert WebSession.safe_return_to("/site-admin-console/agents") == "/site-admin-console/agents"
    assert WebSession.safe_return_to("//evil.example/site-admin-console") == "/"

    assert WebSession.safe_return_to("/\\evil.example/site-admin-console") ==
             "/"

    assert WebSession.safe_return_to("https://evil.example/site-admin-console") ==
             "/"
  end

  test "OIDC authorization stores state and redirects in one browser response", %{conn: conn} do
    assert {:ok, true} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    conn =
      conn
      |> forwarded_https_conn()
      |> init_test_session(%{})
      |> start_console_login(%{"return_to" => "/site-admin-console/agents"})
      |> then(fn conn ->
        get(conn, "/sessions/oidc/lark-main/authorization", %{"flow" => conn.private.login_flow})
      end)

    authorization_url = redirected_to(conn, 302)
    query = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {:ok, oidc_state} = WebSession.login_transaction(conn, conn.private[:login_flow])

    assert URI.parse(authorization_url).host == "open.feishu.cn"
    assert query["state"] == oidc_state.upstream_state

    assert query["redirect_uri"] ==
             "https://#{conn.host}/sessions/oidc/lark-main/callback"

    assert oidc_state.request["return_to"] == "/site-admin-console/agents"
  end

  test "OIDC callback without matching state fails closed", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "missing"})

    assert api_response(conn, 401)["error"] ==
             "login_expired"

    assert WebSession.admin_session(conn) == nil
  end

  test "OIDC callback rejects provider mismatch", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> start_console_login()
      |> then(fn conn ->
        {:ok, _} =
          Ankole.BrowserSessions.bind_provider(
            WebSession.browser_reference(conn),
            conn.private.login_flow,
            "lark-main",
            "state-1",
            "http://localhost/sessions/oidc/lark-main/callback"
          )

        conn
      end)
      |> get(~p"/sessions/oidc/other-main/callback", %{"code" => "code", "state" => "state-1"})

    assert api_response(conn, 401)["error"] ==
             "login_expired"

    assert WebSession.admin_session(conn) == nil
  end

  test "OIDC callback rejects expired state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> start_console_login()
      |> then(fn conn ->
        {:ok, transaction} =
          Ankole.BrowserSessions.bind_provider(
            WebSession.browser_reference(conn),
            conn.private.login_flow,
            "lark-main",
            "state-1",
            "http://localhost/sessions/oidc/lark-main/callback"
          )

        transaction
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
        |> Ankole.Repo.update!()

        conn
      end)
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "state-1"})

    assert api_response(conn, 401)["error"] ==
             "login_expired"

    assert WebSession.admin_session(conn) == nil
  end

  test "bootstrap OIDC state cannot be replayed as admin login after setup is complete", %{
    conn: conn
  } do
    assert {:ok, true} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_oidc_state(%{
        provider_id: "lark-main",
        state: "setup-state",
        redirect_uri: "http://localhost/sessions/oidc/lark-main/callback",
        return_to: "/site-admin-console"
      })
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "setup-state"})

    assert api_response(conn, 409)["error"] ==
             "setup already completed"

    assert WebSession.admin_session(conn) == nil
  end

  defp start_console_login(conn, request \\ %{}) do
    {:ok, conn, transaction} = WebSession.begin_login(conn, :console, request)
    Plug.Conn.put_private(conn, :login_flow, transaction.id)
  end
end
