defmodule AnkoleWeb.AuthControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.LocalPassword.RetryGuard
  alias Ankole.Principals
  alias Ankole.Principals.LocalCredentials
  alias Ankole.Principals.LocalCredential
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.ConsoleTokens
  alias AnkoleWeb.Session, as: WebSession

  import Ankole.PrincipalsFixtures

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

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
    {conn, principal_uid} = active_admin_conn_with_principal(conn)

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
    {conn, _principal_uid} = active_admin_conn_with_principal(conn)

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
    {conn, _principal_uid} = active_admin_conn_with_principal(conn)

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

  test "OIDC authorization stores state and redirects in one browser response", %{conn: conn} do
    assert {:ok, true} = SetupConfig.put_completed(true)

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    conn =
      conn
      |> Map.merge(%{host: "ankole.example.com", port: 80})
      |> init_test_session(%{})
      |> put_req_header("x-forwarded-proto", "https")
      |> get(~p"/sessions/oidc/lark-main/authorization?return_to=%2Fconsole%2Fagents")

    authorization_url = redirected_to(conn, 302)
    query = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    oidc_state = WebSession.admin_oidc_state(conn)

    assert URI.parse(authorization_url).host == "open.feishu.cn"
    assert query["state"] == oidc_state["state"]

    assert query["redirect_uri"] ==
             "https://ankole.example.com/sessions/oidc/lark-main/callback"

    assert oidc_state["return_to"] == "/console/agents"
  end

  test "OIDC callback without matching state fails closed", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "missing"})

    assert json_response(conn, 400)["error"] ==
             "OIDC login expired or was replaced; start sign-in again"

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

    assert json_response(conn, 400)["error"] ==
             "OIDC login expired or was replaced; start sign-in again"

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

    assert json_response(conn, 400)["error"] ==
             "OIDC login expired or was replaced; start sign-in again"

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

  describe "local password sign-in" do
    setup do
      RetryGuard.reset_for_test()
      on_exit(&RetryGuard.reset_for_test/0)

      {:ok, true} = SetupConfig.put_completed(true)
      {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)
      :ok
    end

    test "GET /.internal-apis/identity-providers reports the provider kind", %{conn: conn} do
      conn = get(conn, ~p"/.internal-apis/identity-providers")

      assert %{"providers" => [provider]} = json_response(conn, 200)
      assert provider["providerID"] == "local-main"
      assert provider["adapterID"] == "local"
      assert provider["kind"] == "password"
    end

    test "an admin signs in with email and password", %{conn: conn} do
      %{email: email} = local_admin_user("correct-horse")

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "correct-horse",
          "returnTo" => "https://evil.example/console"
        })

      assert %{"status" => "ok", "returnTo" => "/console"} = json_response(conn, 200)

      conn = get(conn, ~p"/.internal-apis/session")
      assert %{"authenticated" => true, "providerID" => "local-main"} = json_response(conn, 200)
    end

    test "a wrong password and an unknown email return the same error", %{conn: conn} do
      %{email: email} = local_admin_user("correct-horse")

      for {attempt_email, password} <- [{email, "wrong"}, {"nobody@example.com", "wrong"}] do
        conn =
          conn
          |> init_test_session(%{})
          |> post(~p"/.internal-apis/sessions/local-password", %{
            "email" => attempt_email,
            "password" => password
          })

        assert json_response(conn, 401)["error"] == "invalid_credentials"
        assert get_session(conn, :admin_session) == nil
      end
    end

    test "a verified non-admin is refused before any session opens", %{conn: conn} do
      %{email: email} = local_user_with_password("correct-horse")

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "correct-horse"
        })

      assert json_response(conn, 403)["error"] == "not_an_admin"
      assert get_session(conn, :admin_session) == nil
      assert get_session(conn, :local_password_change) == nil
    end

    test "a disabled account is refused with its own error", %{conn: conn} do
      %{principal: principal, email: email} = local_user_with_password("correct-horse")
      {:ok, _principal} = Principals.disable_principal(principal.uid)

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "correct-horse"
        })

      assert json_response(conn, 403)["error"] == "account_disabled"
    end

    test "a must-change credential runs the forced change before any session", %{conn: conn} do
      %{email: email} = local_admin_user("initial-pass", true)

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "initial-pass",
          "returnTo" => "/console/agents"
        })

      assert %{"status" => "password_change_required"} = json_response(conn, 200)
      assert get_session(conn, :admin_session) == nil

      conn =
        post(conn, ~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "short"
        })

      assert json_response(conn, 422)["error"] == "password_too_short"

      conn =
        post(conn, ~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "my-own-password"
        })

      assert %{"returnTo" => "/console/agents"} = json_response(conn, 200)

      conn = get(conn, ~p"/.internal-apis/session")
      assert %{"authenticated" => true} = json_response(conn, 200)

      assert {:error, :invalid_credentials} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "initial-pass")

      assert {:ok, %{must_change_password: false}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "my-own-password")
    end

    test "the change endpoint requires a live ticket", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "my-own-password"
        })

      assert json_response(conn, 401)["error"] == "change_ticket_expired"
    end

    test "the change endpoint refuses a non-admin before writing the password", %{conn: conn} do
      %{principal: principal, email: email, credential_version: credential_version} =
        local_user_with_password("initial-pass", true)

      conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_local_password_change(%{
          principal_uid: principal.uid,
          provider_id: "local-main",
          external_id: email,
          credential_version: credential_version,
          return_to: "/console"
        })
        |> post(~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "my-own-password"
        })

      assert json_response(conn, 403)["error"] == "not_an_admin"
      assert get_session(conn, :admin_session) == nil

      assert {:ok, %{must_change_password: true}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "initial-pass")
    end

    test "a change ticket cannot be replayed to set a second password", %{conn: conn} do
      %{email: email} = local_admin_user("initial-pass", true)

      login_conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "initial-pass"
        })

      assert %{"status" => "password_change_required"} = json_response(login_conn, 200)
      assert is_integer(WebSession.local_password_change(login_conn)["credential_version"])

      first =
        post(login_conn, ~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "first-choice-pass"
        })

      assert %{"returnTo" => _return_to} = json_response(first, 200)

      replay =
        post(login_conn, ~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "replayed-pass-123"
        })

      assert json_response(replay, 401)["error"] == "change_ticket_expired"
      assert get_session(replay, :admin_session) == nil

      assert {:ok, %{must_change_password: false}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "first-choice-pass")

      assert {:error, :invalid_credentials} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "replayed-pass-123")
    end

    test "a password reset invalidates an earlier change ticket", %{conn: conn} do
      %{principal: principal, email: email} = local_admin_user("initial-pass", true)

      login_conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "initial-pass"
        })

      assert %{"status" => "password_change_required"} = json_response(login_conn, 200)
      assert {:ok, reset_password} = LocalCredentials.reset_local_password(principal.uid, true)

      replay =
        post(login_conn, ~p"/.internal-apis/sessions/local-password/change", %{
          "newPassword" => "stale-ticket-password"
        })

      assert json_response(replay, 401)["error"] == "change_ticket_expired"
      assert get_session(replay, :admin_session) == nil

      assert {:ok, %{must_change_password: true}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, reset_password)

      assert {:error, :invalid_credentials} =
               Ankole.IdentityProviders.LocalPassword.authenticate(
                 email,
                 "stale-ticket-password"
               )
    end

    test "five failures lock the account with a retry delay", %{conn: conn} do
      %{email: email} = local_admin_user("correct-horse")

      for _attempt <- 1..5 do
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "wrong"
        })
      end

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => email,
          "password" => "correct-horse"
        })

      response = json_response(conn, 429)
      assert response["error"] == "retry_locked"
      assert response["retryAfterSeconds"] in 1..(30 * 60)
    end

    test "sign-in is refused while setup is incomplete", %{conn: conn} do
      {:ok, false} = SetupConfig.put_completed(false)

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "email" => "admin@example.com",
          "password" => "correct-horse"
        })

      assert json_response(conn, 409)["error"] == "setup is not complete"
    end
  end

  defp local_user_with_password(password, must_change \\ false) do
    %{principal: principal, human_user: human_user} = human_fixture()
    {:ok, credential} = LocalCredentials.set_local_password(principal.uid, password, must_change)

    %{
      principal: principal,
      email: human_user.email,
      credential_version: LocalCredential.version(credential)
    }
  end

  defp local_admin_user(password, must_change \\ false) do
    %{principal: principal, email: email} = local_user_with_password(password, must_change)
    {:ok, _root} = AuthZ.root_init_admin(principal.uid)
    %{principal: principal, email: email}
  end
end
