defmodule AnkoleWeb.AuthControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.IdentityProviders.LocalPassword.RetryGuard
  alias Ankole.Principals.LocalCredential
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  import Ankole.PrincipalsFixtures

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "return_to keeps local paths and rejects protocol-relative or backslash-relative paths" do
    assert WebSession.safe_return_to("/site-admin-console") == "/site-admin-console"
    assert WebSession.safe_return_to("/site-admin-console/agents") == "/site-admin-console/agents"
    assert WebSession.safe_return_to("//evil.example/site-admin-console") == "/workplace"

    assert WebSession.safe_return_to("/\\evil.example/site-admin-console") ==
             "/workplace"

    assert WebSession.safe_return_to("https://evil.example/site-admin-console") ==
             "/workplace"
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
             "https://ankole.example.com/sessions/oidc/lark-main/callback"

    assert oidc_state.request["return_to"] == "/site-admin-console/agents"
  end

  test "OIDC callback without matching state fails closed", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "missing"})

    assert json_response(conn, 401)["error"] ==
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

    assert json_response(conn, 401)["error"] ==
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

    assert json_response(conn, 401)["error"] ==
             "login_expired"

    assert WebSession.admin_session(conn) == nil
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
        return_to: "/site-admin-console"
      })
      |> get(~p"/sessions/oidc/lark-main/callback", %{"code" => "code", "state" => "setup-state"})

    assert json_response(conn, 409)["error"] == "setup already completed"
    assert WebSession.admin_session(conn) == nil
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

    test "legacy cookie authentication is ignored and the browser can sign in", %{
      conn: conn,
      tenant: tenant
    } do
      %{principal: principal, email: email} = local_admin_user("correct-horse")

      conn =
        conn
        |> init_test_session(%{
          admin_session: %{"principal_uid" => principal.uid},
          oauth_authorization: %{"principal_uid" => principal.uid}
        })
        |> get(~p"/site-admin-console")

      assert redirected_to(conn) == ~p"/sessions/new?return_to=%2Fsite-admin-console"
      assert WebSession.admin_session(conn) == nil
      Ankole.Repo.put_tenant_id(tenant.id)

      conn = conn |> recycle() |> get(~p"/sessions/new")
      flow = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      conn =
        conn
        |> recycle()
        |> post(~p"/.internal-apis/sessions/local-password", %{
          "flow" => flow["flow"],
          "email" => email,
          "password" => "correct-horse"
        })

      assert %{"status" => "ok"} = json_response(conn, 200)
      assert WebSession.admin_session(conn)["principal_uid"] == principal.uid
    end

    test "an admin signs in with email and password", %{conn: conn} do
      %{email: email} = local_admin_user("correct-horse")

      conn =
        conn
        |> init_test_session(%{})
        |> post_password(%{
          "email" => email,
          "password" => "correct-horse",
          "returnTo" => "https://evil.example/site-admin-console"
        })

      assert %{"status" => "ok", "returnTo" => "/workplace"} = json_response(conn, 200)

      conn = get(conn, ~p"/.internal-apis/session")
      assert %{"authenticated" => true, "providerID" => "local-main"} = json_response(conn, 200)
    end

    test "a wrong password and an unknown email return the same error", %{conn: conn} do
      %{email: email} = local_admin_user("correct-horse")

      for {attempt_email, password} <- [{email, "wrong"}, {"nobody@example.com", "wrong"}] do
        conn =
          conn
          |> init_test_session(%{})
          |> post_password(%{
            "email" => attempt_email,
            "password" => password
          })

        assert json_response(conn, 401)["error"] == "invalid_credentials"
        assert WebSession.admin_session(conn) == nil
      end
    end

    test "a verified non-admin is refused before any session opens", %{conn: conn} do
      %{email: email} = local_user_with_password("correct-horse")

      conn =
        conn
        |> init_test_session(%{})
        |> post_password(%{
          "email" => email,
          "password" => "correct-horse"
        })

      assert json_response(conn, 403)["error"] == "not_an_admin"
      assert WebSession.admin_session(conn) == nil
    end

    test "a verified non-admin can open only the OAuth Human session", %{conn: conn} do
      %{principal: principal, email: email} = local_user_with_password("correct-horse")

      {:ok, %{client: client}} =
        Ankole.OIDC.create_client(%{
          name: "Password RP",
          enabled: true,
          type: "public",
          redirect_uris: ["https://client.example.test/callback"],
          scopes: ["openid"]
        })

      conn = init_test_session(conn, %{})

      {:ok, conn, transaction} =
        WebSession.begin_login(conn, :oauth, %{
          "client_id" => client.id,
          "redirect_uri" => "https://client.example.test/callback"
        })

      conn =
        conn
        |> Plug.Conn.put_private(:login_flow, transaction.id)
        |> post_password(%{"email" => email, "password" => "correct-horse"})

      assert %{"status" => "ok", "returnTo" => return_to} = json_response(conn, 200)
      assert return_to == "/oauth/authorize/resume?flow=" <> transaction.id

      assert %{"principal_uid" => principal_uid} = WebSession.oauth_session(conn)
      assert principal_uid == principal.uid
      assert WebSession.admin_session(conn) == nil
    end

    test "a disabled account is refused with its own error", %{conn: conn} do
      %{principal: principal, email: email} = local_user_with_password("correct-horse")
      {:ok, _principal} = Ankole.PrincipalsFixtures.disable_principal_fixture(principal.uid)

      conn =
        conn
        |> init_test_session(%{})
        |> post_password(%{
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
        |> post_password(%{
          "email" => email,
          "password" => "initial-pass",
          "returnTo" => "/site-admin-console/agents"
        })

      assert %{"status" => "password_change_required"} = json_response(conn, 200)
      assert WebSession.admin_session(conn) == nil

      conn =
        post_change(conn, %{
          "newPassword" => "short"
        })

      assert json_response(conn, 422)["error"] == "password_too_short"

      conn =
        post_change(conn, %{
          "newPassword" => "my-own-password"
        })

      assert %{"returnTo" => "/site-admin-console/agents"} = json_response(conn, 200)

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
        |> post_change(%{
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
        |> start_console_login()
        |> then(fn conn ->
          {:ok, _} =
            Ankole.BrowserSessions.bind_provider(
              WebSession.browser_reference(conn),
              conn.private.login_flow,
              "local-main"
            )

          {:ok, _} =
            Ankole.BrowserSessions.put_password_ticket(
              WebSession.browser_reference(conn),
              conn.private.login_flow,
              %{
                "principal_uid" => principal.uid,
                "provider_id" => "local-main",
                "external_id" => email,
                "credential_version" => credential_version,
                "access_version" => principal.access_version,
                "auth_time" => System.system_time(:second)
              }
            )

          conn
        end)
        |> post_change(%{
          "newPassword" => "my-own-password"
        })

      assert json_response(conn, 403)["error"] == "not_an_admin"
      assert WebSession.admin_session(conn) == nil

      assert {:ok, %{must_change_password: true}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "initial-pass")
    end

    test "a change ticket cannot be replayed to set a second password", %{
      conn: conn,
      tenant: tenant
    } do
      %{email: email} = local_admin_user("initial-pass", true)

      login_conn =
        conn
        |> init_test_session(%{})
        |> post_password(%{
          "email" => email,
          "password" => "initial-pass"
        })

      assert %{"status" => "password_change_required"} = json_response(login_conn, 200)
      {:ok, transaction} = WebSession.login_transaction(login_conn, login_conn.private.login_flow)
      assert is_integer(transaction.password_ticket["credential_version"])

      first =
        post_change(login_conn, %{
          "newPassword" => "first-choice-pass"
        })

      assert %{"returnTo" => _return_to} = json_response(first, 200)

      replay =
        post_change(login_conn, %{
          "newPassword" => "replayed-pass-123"
        })

      assert json_response(replay, 401)["error"] == "change_ticket_expired"
      assert WebSession.admin_session(replay) == nil
      Ankole.Repo.put_tenant_id(tenant.id)

      assert {:ok, %{must_change_password: false}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "first-choice-pass")

      assert {:error, :invalid_credentials} =
               Ankole.IdentityProviders.LocalPassword.authenticate(email, "replayed-pass-123")
    end

    test "a password reset invalidates an earlier change ticket", %{conn: conn, tenant: tenant} do
      %{principal: principal, email: email} = local_admin_user("initial-pass", true)

      login_conn =
        conn
        |> init_test_session(%{})
        |> post_password(%{
          "email" => email,
          "password" => "initial-pass"
        })

      assert %{"status" => "password_change_required"} = json_response(login_conn, 200)
      assert {:ok, reset_password} = LocalPassword.reset_local_password(principal.uid, true)

      replay =
        post_change(login_conn, %{
          "newPassword" => "stale-ticket-password"
        })

      assert json_response(replay, 401)["error"] == "change_ticket_expired"
      assert WebSession.admin_session(replay) == nil
      Ankole.Repo.put_tenant_id(tenant.id)

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
        |> post_password(%{
          "email" => email,
          "password" => "wrong"
        })
      end

      conn =
        conn
        |> init_test_session(%{})
        |> post_password(%{
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
        |> post_password(%{
          "email" => "admin@example.com",
          "password" => "correct-horse"
        })

      assert json_response(conn, 409)["error"] == "setup is not complete"
    end
  end

  defp start_console_login(conn, request \\ %{}) do
    {:ok, conn, transaction} = WebSession.begin_login(conn, :console, request)
    Plug.Conn.put_private(conn, :login_flow, transaction.id)
  end

  defp post_password(conn, params) do
    conn =
      if conn.private[:login_flow],
        do: conn,
        else: start_console_login(conn, %{"return_to" => params["returnTo"]})

    post(
      conn,
      "/.internal-apis/sessions/local-password",
      Map.put(params, "flow", conn.private.login_flow)
    )
    |> Plug.Conn.put_private(:login_flow, conn.private.login_flow)
  end

  defp post_change(conn, params) do
    post(
      conn,
      "/.internal-apis/sessions/local-password/change",
      Map.put(params, "flow", conn.private[:login_flow])
    )
    |> Plug.Conn.put_private(:login_flow, conn.private[:login_flow])
  end

  defp local_user_with_password(password, must_change \\ false) do
    %{principal: principal, human_user: human_user} = human_fixture()
    {:ok, credential} = LocalPassword.set_local_password(principal.uid, password, must_change)

    %{
      principal: principal,
      email: human_user.email,
      credential_version: LocalCredential.version(credential)
    }
  end

  defp local_admin_user(password, must_change \\ false) do
    %{principal: principal, email: email} = local_user_with_password(password, must_change)
    {:ok, _root} = Ankole.PrincipalsFixtures.first_site_admin_fixture(principal.uid)
    %{principal: principal, email: email}
  end
end
