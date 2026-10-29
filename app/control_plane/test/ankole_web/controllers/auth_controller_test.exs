defmodule AnkoleWeb.AuthControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI

  alias Ankole.AppConfigure.Registry
  alias Ankole.IdentityProviders
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Registry.clear_for_test()

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
      |> get("/sessions/oidc/lark-main/authorization", %{
        "purpose" => "console",
        "return_to" => "/site-admin-console/agents"
      })

    authorization_url = redirected_to(conn, 302)
    query = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    oidc_state = Ankole.Repo.one!(Ankole.BrowserSessions.OidcState)

    assert URI.parse(authorization_url).host == "open.feishu.cn"
    assert query["state"] == oidc_state.state

    assert query["redirect_uri"] ==
             "https://#{conn.host}/sessions/oidc/lark-main/callback"

    assert oidc_state.purpose == :console
    assert oidc_state.return_to == "/site-admin-console/agents"
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
      |> WebSession.ensure_browser()
      |> then(fn conn ->
        {:ok, _} =
          Ankole.BrowserSessions.begin_oidc_state(WebSession.browser_reference(conn), %{
            state: "state-1",
            provider_id: "lark-main",
            purpose: :console,
            redirect_uri: "http://localhost/sessions/oidc/lark-main/callback"
          })

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
      |> WebSession.ensure_browser()
      |> then(fn conn ->
        {:ok, oidc_state} =
          Ankole.BrowserSessions.begin_oidc_state(WebSession.browser_reference(conn), %{
            state: "state-1",
            provider_id: "lark-main",
            purpose: :console,
            redirect_uri: "http://localhost/sessions/oidc/lark-main/callback"
          })

        oidc_state
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

  test "requesting email OTP and starting SSO do not lock out switching between sign-in methods",
       %{conn: conn, tenant: tenant} do
    Ankole.Authn.RateLimiter.reset_for_test()
    previous_mailer = Application.get_env(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Test)

    on_exit(fn ->
      if previous_mailer,
        do: Application.put_env(:ankole, Ankole.Authn.Mailer, previous_mailer),
        else: Application.delete_env(:ankole, Ankole.Authn.Mailer)
    end)

    assert {:ok, true} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    assert {:ok, _} =
             Ankole.Authn.Config.put_mail(%{
               "server" => "smtp.example.com",
               "from" => "login@example.com"
             })

    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_switch", "appSecret" => "secret"},
               true
             )

    {:ok, %{principal: member}} =
      Ankole.Principals.create_human(%{
        email: "switch-methods@example.com",
        display_name: "Method Switcher"
      })

    otp_origin =
      if @host_policy do
        site = URI.parse(AnkoleWeb.PodURL.site_origin(conn))
        URI.to_string(%{site | host: String.replace_prefix(site.host, "console.", "accounts.")})
      else
        AnkoleWeb.PodURL.origin(conn, tenant)
      end

    otp_uri = URI.parse(otp_origin)

    otp_payload =
      if @host_policy do
        %{email: "switch-methods@example.com", tenantID: tenant.id, returnTo: "/content/space"}
      else
        %{email: "switch-methods@example.com", returnTo: "/content/space"}
      end

    conn =
      %{
        conn
        | host: otp_uri.host,
          port: otp_uri.port,
          scheme: String.to_existing_atom(otp_uri.scheme)
      }
      |> init_test_session(%{})
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", otp_payload)

    %{"challengeID" => challenge_id} = api_response(conn, 200)
    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    sso_first =
      conn
      |> recycle()
      |> delete_req_header("accept")
      |> pod_conn(tenant)
      |> get("/sessions/oidc/lark-main/authorization", %{"return_to" => "/content/space"})

    first_state =
      sso_first |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    sso_retry =
      sso_first
      |> recycle()
      |> delete_req_header("accept")
      |> pod_conn(tenant)
      |> get("/sessions/oidc/lark-main/authorization", %{"return_to" => "/content/space"})

    retry_state =
      sso_retry |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert is_binary(first_state["state"])
    assert is_binary(retry_state["state"])
    assert first_state["state"] != retry_state["state"]

    verified =
      sso_retry
      |> recycle()
      |> Map.merge(%{
        host: otp_uri.host,
        port: otp_uri.port,
        scheme: String.to_existing_atom(otp_uri.scheme)
      })
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge_id,
        code: code
      })

    assert %{"status" => "ok", "returnTo" => return_to} = api_response(verified, 200)
    assert String.ends_with?(return_to, "/content/space")

    entered =
      if @host_policy do
        verified
        |> recycle()
        |> delete_req_header("accept")
        |> pod_conn(tenant)
        |> get("/content/space")
      else
        verified
      end

    assert WebSession.pod_session(entered)["principal_uid"] == member.uid
  end
end
