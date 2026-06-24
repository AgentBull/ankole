defmodule AnkoleWeb.AuthControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.ConsoleTokens
  alias AnkoleWeb.Session, as: WebSession

  import Ankole.PrincipalsFixtures

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "return_to keeps local paths and rejects protocol-relative or backslash-relative paths" do
    assert WebSession.safe_return_to("/console") == "/console"
    assert WebSession.safe_return_to("/console/agents") == "/console/agents"
    assert WebSession.safe_return_to("//evil.example/console") == "/console"
    assert WebSession.safe_return_to("/\\evil.example/console") == "/console"
    assert WebSession.safe_return_to("https://evil.example/console") == "/console"
  end

  test "POST /.internal-apis/oauth/token exchanges an active admin session for bearer tokens", %{
    conn: conn
  } do
    {conn, principal_uid} = active_admin_conn(conn)

    conn =
      post(conn, ~p"/.internal-apis/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "token_type" => "Bearer",
             "expires_in" => expires_in,
             "refresh_token_expires_in" => refresh_expires_in,
             "scope" => "web_console"
           } = json_response(conn, 200)

    assert is_binary(access_token)
    assert is_binary(refresh_token)
    assert expires_in in 1..1800
    assert refresh_expires_in >= expires_in

    assert {:ok, %{"sub" => ^principal_uid, "token_use" => "access"}} =
             ConsoleTokens.verify_access_token(access_token)
  end

  test "POST /.internal-apis/oauth/token refreshes only against the current admin session", %{
    conn: conn
  } do
    {conn, _principal_uid} = active_admin_conn(conn)

    conn =
      post(conn, ~p"/.internal-apis/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })

    %{"access_token" => access_token, "refresh_token" => refresh_token} = json_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> post(~p"/.internal-apis/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      })

    assert %{"access_token" => refreshed_access, "refresh_token" => refreshed_refresh} =
             json_response(conn, 200)

    assert refreshed_access != access_token
    assert refreshed_refresh != refresh_token

    conn =
      conn
      |> recycle()
      |> post(~p"/.internal-apis/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => access_token
      })

    assert %{"error" => "invalid_grant"} = json_response(conn, 400)
  end

  test "refresh grant fails when the refresh token subject differs from the cookie session", %{
    conn: conn
  } do
    {conn, _principal_uid} = active_admin_conn(conn)

    conn =
      post(conn, ~p"/.internal-apis/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })

    %{"refresh_token" => refresh_token} = json_response(conn, 200)
    second_admin = human_fixture(%{uid: unique_uid("second-console-admin")})
    assert {:ok, _membership} = AuthZ.add_principal_to_group(second_admin.principal.uid, "admin")

    conn =
      conn
      |> recycle()
      |> init_test_session(%{})
      |> WebSession.put_admin_session(%{
        principal_uid: second_admin.principal.uid,
        provider_id: "lark-main",
        external_id: "external-2"
      })
      |> post(~p"/.internal-apis/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      })

    assert %{"error" => "invalid_grant"} = json_response(conn, 400)
  end

  test "POST /.internal-apis/oauth/token rejects missing admin session", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> post(~p"/.internal-apis/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })

    assert %{"error" => "invalid_grant"} = json_response(conn, 401)
  end

  test "OIDC callback without matching state fails closed", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "missing"})

    assert json_response(conn, 400)["error"] == "invalid OIDC state"
    assert get_session(conn, :admin_session) == nil
  end

  test "OIDC callback rejects provider mismatch", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_admin_oidc_state(%{
        provider_id: "lark-main",
        state: "state-1",
        redirect_uri: "http://localhost/sessions/oidc/lark-main/callback",
        return_to: "/console"
      })
      |> get(~p"/sessions/oidc/other-main/callback", %{"code" => "code", "state" => "state-1"})

    assert json_response(conn, 400)["error"] == "invalid OIDC state"
    assert get_session(conn, :admin_session) == nil
  end

  test "OIDC callback rejects expired state", %{conn: conn} do
    expired_at = System.system_time(:second) - 1

    conn =
      conn
      |> init_test_session(%{
        admin_oidc_state: %{
          "provider_id" => "lark-main",
          "state" => "state-1",
          "redirect_uri" => "http://localhost/sessions/oidc/lark-main/callback",
          "return_to" => "/console",
          "expires_at" => expired_at
        }
      })
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "state-1"})

    assert json_response(conn, 400)["error"] == "invalid OIDC state"
    assert get_session(conn, :admin_session) == nil
  end

  test "bootstrap OIDC state cannot be replayed as admin login after setup is complete", %{
    conn: conn
  } do
    assert {:ok, true} = SetupConfig.put_completed(true)

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_oidc_state(%{
        provider_id: "lark-main",
        state: "setup-state",
        redirect_uri: "http://localhost/sessions/oidc/lark-main/callback",
        return_to: "/console"
      })
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "setup-state"})

    assert json_response(conn, 409)["error"] == "setup already completed"
    assert get_session(conn, :admin_session) == nil
    assert get_session(conn, :admin_oidc_state) == nil
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_admin_session(%{
        principal_uid: human.principal.uid,
        provider_id: "lark-main",
        external_id: "external-1"
      })

    {conn, human.principal.uid}
  end
end
