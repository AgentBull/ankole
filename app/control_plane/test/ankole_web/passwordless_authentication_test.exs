defmodule AnkoleWeb.PasswordlessAuthenticationTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Principals, Repo}
  alias Ankole.Principals.HumanAccess
  alias AnkoleWeb.Session, as: WebSession

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    Ankole.Authn.RateLimiter.reset_for_test()
    previous = Application.get_env(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Test)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, Ankole.Authn.Mailer, previous),
        else: Application.delete_env(:ankole, Ankole.Authn.Mailer)
    end)

    :ok
  end

  test "FOSS setup requires a delivered email code and establishes both administrator roles and a Console proof",
       %{conn: conn, tenant: tenant} do
    {:ok, false} = AppConfigure.put_global_by_key("setup.completed", false)
    {:ok, _} = AppConfigure.put_global_by_key("authn.email.mail", nil)

    settings = %{
      "server" => "smtp.example.com",
      "from" => "login@example.com",
      "password" => "smtp-secret"
    }

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_post("/api/v2/browser/setup/email-otp/challenges", %{
        email: "operator@example.com",
        display_name: "Operator",
        mail: settings
      })

    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:email, %Swoosh.Email{to: [{_, "operator@example.com"}], text_body: body}}
    assert {:ok, false} = Ankole.Setup.Config.completed?()
    assert {:ok, nil} = AppConfigure.get_by_key("authn.email.mail")
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/setup/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    assert %{"returnTo" => "/site-admin-console"} = api_response(conn, 200)
    assert {:ok, true} = Ankole.Setup.Config.completed?()
    assert %{"principal_uid" => uid} = WebSession.site_admin_session(conn)

    assert {:ok, %{scope: :site, challenge_started_at: %DateTime{}}} =
             BrowserSessions.get_authentication(WebSession.authentication_reference(conn))

    assert AuthZ.site_admin?(uid)
    assert Repo.with_tenant(tenant.id, fn -> AuthZ.pod_admin?(uid) end)
    assert {:ok, ^settings} = AppConfigure.get_by_key("authn.email.mail")
  end

  test "one verified credential lists and switches two independent Pod memberships without changing a pinned tab",
       %{conn: conn, tenant: first} do
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)

    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.mail", %{
        "server" => "smtp.example.com",
        "from" => "login@example.com"
      })

    second = Ankole.DataCase.create_tenant()

    proof = %{
      provider_id: "email_otp",
      subject_id: "person@example.com",
      verified_email: "person@example.com"
    }

    members =
      for tenant <- [first, second] do
        Repo.with_tenant(tenant.id, fn ->
          {:ok, %{principal: member}} =
            Principals.create_human(%{email: proof.subject_id, display_name: tenant.slug})

          {:ok, _} =
            Repo.transact(fn -> Principals.bind_site_credential_in_tx(member.uid, proof) end)

          member
        end)
      end

    {otp_conn, challenge_params} =
      if @host_policy do
        {accounts_conn(conn), %{tenantID: first.id, email: proof.subject_id}}
      else
        {pod_conn(conn, first), %{email: proof.subject_id}}
      end

    conn =
      otp_conn
      |> init_test_session(%{})
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", challenge_params)

    %{"challengeID" => id} = api_response(conn, 200)
    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    conn =
      %{recycle(conn) | host: otp_conn.host, port: otp_conn.port, scheme: otp_conn.scheme}
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: id,
        code: code
      })

    assert %{"status" => "ok"} = api_response(conn, 200)

    session_origin = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, first)

    conn =
      %{
        recycle(conn)
        | host: session_origin.host,
          port: session_origin.port,
          scheme: session_origin.scheme
      }
      |> api_get("/api/v2/browser/session")

    %{"accounts" => accounts} = api_response(conn, 200)

    assert MapSet.new(Enum.map(accounts, & &1["principalUID"])) ==
             MapSet.new(Enum.map(members, & &1.uid))

    [account] = Enum.filter(accounts, &(&1["tenant"]["id"] == first.id))
    reference = account["authenticationRef"]

    conn =
      %{
        recycle(conn)
        | host: session_origin.host,
          port: session_origin.port,
          scheme: session_origin.scheme
      }
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: reference,
        tenantID: second.id
      })

    assert %{"podURL" => _} = api_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> pod_conn(first)
      |> put_req_header("x-ankole-authentication", reference)
      |> put_req_header("x-ankole-pod", first.id)
      |> api_get("/api/v2/browser/session")

    assert api_response(conn, 200)["principalUID"] == hd(members).uid
  end

  test "an unfinished setup blocks ordinary OTP login", %{conn: conn, tenant: tenant} do
    {:ok, _} = AppConfigure.put_global_by_key("setup.completed", false)
    target_conn = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, tenant)

    conn =
      target_conn
      |> init_test_session(%{})
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
        email: "member@example.com"
      })

    assert api_error(conn, 409)
    refute_receive {:email, _}
  end

  test "Console entry seals console_return, returns to Console after OTP login, grants siteadmins access, and blocks non-admins with 403",
       %{conn: conn, tenant: tenant} do
    {:ok, _} = AppConfigure.put_global_by_key("setup.completed", true)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "smtp.example.com",
        "from" => "login@example.com"
      })

    {:ok, %{principal: member}} =
      Principals.create_human(%{email: "member@example.com", display_name: "Member"})

    {primary_admin, disabled_admin} =
      Ankole.Repo.with_tenant(tenant.id, fn ->
        {:ok, %{principal: primary_admin}} =
          Principals.create_human(%{email: "primary-admin@example.com", display_name: "Primary"})

        {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(primary_admin.uid)

        {:ok, %{principal: disabled_admin}} =
          Principals.create_human(%{email: "disabled-admin@example.com", display_name: "Admin"})

        {:ok, _} = AuthZ.add_principal_to_group(disabled_admin.uid, "siteadmin")

        {:ok, _} =
          HumanAccess.disable(
            disabled_admin.uid,
            "suspended",
            nil,
            "suspend-console-admin",
            :suspended
          )

        {primary_admin, disabled_admin}
      end)

    refute AuthZ.site_admin?(member.uid)
    assert AuthZ.site_admin_member?(disabled_admin.uid)
    refute AuthZ.site_admin?(disabled_admin.uid)

    console_entry = conn |> init_test_session(%{}) |> get("/site-admin-console/settings")
    redirect_url = redirected_to(console_entry)
    refute redirect_url =~ "/site-admin-console"

    console_return =
      URI.parse(redirect_url).query |> URI.decode_query() |> Map.fetch!("console_return")

    otp_origin = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, tenant)

    base_params =
      if @host_policy,
        do: %{tenantID: tenant.id, consoleReturn: console_return},
        else: %{consoleReturn: console_return}

    disabled_sent =
      otp_origin
      |> init_test_session(%{})
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(base_params, :email, "disabled-admin@example.com")
      )

    %{"challengeID" => disabled_challenge} = api_response(disabled_sent, 200)

    assert_receive {:email,
                    %Swoosh.Email{to: [{_, "disabled-admin@example.com"}], text_body: body}}

    [_, disabled_code] = Regex.run(~r/code is (\d{6})/, body)

    disabled_resp =
      %{
        recycle(disabled_sent)
        | host: otp_origin.host,
          port: otp_origin.port,
          scheme: otp_origin.scheme
      }
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: disabled_challenge,
        code: disabled_code
      })

    assert api_error(disabled_resp, 403)["code"] == "account_disabled"
    refute WebSession.site_admin_session(disabled_resp)

    admin_sent =
      otp_origin
      |> init_test_session(%{})
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(base_params, :email, "primary-admin@example.com")
      )

    %{"challengeID" => admin_challenge} = api_response(admin_sent, 200)

    assert_receive {:email,
                    %Swoosh.Email{to: [{_, "primary-admin@example.com"}], text_body: admin_body}}

    [_, admin_code] = Regex.run(~r/code is (\d{6})/, admin_body)

    admin_verified =
      %{
        recycle(admin_sent)
        | host: otp_origin.host,
          port: otp_origin.port,
          scheme: otp_origin.scheme
      }
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: admin_challenge,
        code: admin_code
      })

    expected_console_url = AnkoleWeb.PodURL.site_origin(conn) <> "/site-admin-console/settings"
    assert api_response(admin_verified, 200)["returnTo"] == expected_console_url
    assert WebSession.site_admin_session(admin_verified)["principal_uid"] == primary_admin.uid

    admin_console =
      admin_verified
      |> recycle()
      |> delete_req_header("accept")
      |> site_conn()
      |> get("/site-admin-console/settings")

    assert html_response(admin_console, 200) =~
             ~s(<meta name="ankole-principal" content="#{primary_admin.uid}">)

    member_sent =
      otp_origin
      |> init_test_session(%{})
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(base_params, :email, "member@example.com")
      )

    %{"challengeID" => member_challenge} = api_response(member_sent, 200)

    assert_receive {:email,
                    %Swoosh.Email{to: [{_, "member@example.com"}], text_body: member_body}}

    [_, member_code] = Regex.run(~r/code is (\d{6})/, member_body)

    member_verified =
      %{
        recycle(member_sent)
        | host: otp_origin.host,
          port: otp_origin.port,
          scheme: otp_origin.scheme
      }
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: member_challenge,
        code: member_code
      })

    assert api_response(member_verified, 200)["returnTo"] == expected_console_url
    refute WebSession.site_admin_session(member_verified)

    member_console =
      member_verified
      |> recycle()
      |> delete_req_header("accept")
      |> site_conn()
      |> get("/site-admin-console/settings")

    assert member_console.status == 403
    assert member_console.resp_body == "Site administrator access required"
    assert get_resp_header(member_console, "location") == []
  end

  test "edition login boundaries enforce FOSS registration disablement and SaaS Pod OTP disablement",
       %{conn: conn, tenant: tenant} do
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "smtp.example.com",
        "from" => "login@example.com"
      })

    if @host_policy do
      providers_conn =
        conn
        |> pod_conn(tenant)
        |> init_test_session(%{})
        |> api_get("/api/v2/browser/identity-providers")

      refute Enum.any?(
               api_response(providers_conn, 200)["providers"],
               &(&1["providerID"] == "email_otp")
             )

      denied =
        providers_conn
        |> recycle()
        |> pod_conn(tenant)
        |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
          email: "member@example.com"
        })

      assert api_error(denied, 400)["code"] == "identity_provider_not_allowed"
      refute_receive {:email, _}
    else
      providers_conn =
        conn
        |> init_test_session(%{})
        |> api_get("/api/v2/browser/identity-providers")

      assert api_error(providers_conn, 401)["code"] == "login_expired"

      denied =
        conn
        |> init_test_session(%{})
        |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
          email: "self-register@example.com"
        })

      assert api_error(denied, 401)["code"] == "login_expired"
      refute_receive {:email, _}
    end
  end

  test "disabled and SSO-gated Pod members still receive OTP emails and see explicit verification errors",
       %{conn: conn, tenant: tenant} do
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "smtp.example.com",
        "from" => "login@example.com"
      })

    {:ok, %{principal: admin}} =
      Principals.create_human(%{email: "pod-admin@example.com", display_name: "Pod Admin"})

    {:ok, %{principal: disabled_member}} =
      Principals.create_human(%{email: "disabled@example.com", display_name: "Disabled"})

    {:ok, %{principal: _sso_member}} =
      Principals.create_human(%{email: "sso-only@example.com", display_name: "SSO Only"})

    {:ok, _} = HumanAccess.disable(disabled_member.uid, "suspended", nil, "suspend-1", :suspended)

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "corp-sso",
        "lark",
        %{"appID" => "cli_debug_errors", "appSecret" => "secret"},
        true
      )

    {:ok, _} =
      Ankole.PrincipalsFixtures.create_external_identity(%{
        principal_uid: admin.uid,
        provider: "corp-sso",
        external_id: "pod-admin-ext"
      })

    {:ok, settings} = Ankole.Principals.PodAdministration.settings()

    {:ok, _} =
      Ankole.Principals.PodAdministration.update_settings(
        Ankole.AuthZ.Actor.new(admin),
        Map.put(
          settings,
          :loginPolicy,
          Map.put(settings.loginPolicy, "require_sso_for_members", true)
        )
      )

    otp_origin = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, tenant)
    base_params = if @host_policy, do: %{tenantID: tenant.id}, else: %{}

    for {email, expected_error} <- [
          {"disabled@example.com", "account_disabled"},
          {"sso-only@example.com", "login_policy_rejected"}
        ] do
      sent =
        otp_origin
        |> init_test_session(%{})
        |> api_post(
          "/api/v2/browser/sessions/email-otp/challenges",
          Map.put(base_params, :email, email)
        )

      %{"challengeID" => challenge_id} = api_response(sent, 200)
      assert_receive {:email, %Swoosh.Email{to: [{_, ^email}], text_body: body}}
      [_, code] = Regex.run(~r/code is (\d{6})/, body)

      verified =
        %{recycle(sent) | host: otp_origin.host, port: otp_origin.port, scheme: otp_origin.scheme}
        |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
          challengeID: challenge_id,
          code: code
        })

      assert api_error(verified, 403)["code"] == expected_error
    end
  end

  test "local mailbox preview serves localized OTP emails in development mode without SMTP settings",
       %{conn: conn, tenant: tenant} do
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Local)
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)
    {:ok, _} = AppConfigure.put_global_by_key("authn.email.mail", nil)
    Swoosh.Adapters.Local.Storage.Memory.delete_all()
    on_exit(fn -> Swoosh.Adapters.Local.Storage.Memory.delete_all() end)

    {:ok, %{principal: member}} =
      Principals.create_human(%{email: "dev-login@example.com", display_name: "Dev Member"})

    {:ok, _} =
      Repo.transact(fn ->
        Principals.bind_site_credential_in_tx(member.uid, %{
          provider_id: "email_otp",
          subject_id: "dev-login@example.com",
          verified_email: "dev-login@example.com"
        })
      end)

    {target_conn, provider_query, challenge_payload} =
      if @host_policy do
        {accounts_conn(conn), %{tenant_id: tenant.id},
         %{tenantID: tenant.id, email: "dev-login@example.com"}}
      else
        {pod_conn(conn, tenant), %{}, %{email: "dev-login@example.com"}}
      end

    providers_conn =
      target_conn
      |> init_test_session(%{})
      |> api_get("/api/v2/browser/identity-providers", provider_query)

    assert Enum.any?(
             api_response(providers_conn, 200)["providers"],
             &(&1["providerID"] == "email_otp")
           )

    challenge_conn =
      %{
        recycle(providers_conn)
        | host: target_conn.host,
          port: target_conn.port,
          scheme: target_conn.scheme
      }
      |> put_req_header("accept-language", "zh-CN,zh;q=0.9,en;q=0.8")
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", challenge_payload)

    %{"challengeID" => challenge_id} = api_response(challenge_conn, 200)

    json_conn = get(build_conn(), "/dev/mailbox/json")
    assert %{"data" => [rendered]} = json_response(json_conn, 200)
    assert rendered["subject"] == "Ankole 邮箱验证码"
    assert rendered["html_body"] =~ ~s(lang="zh-Hans-CN")
    [_, code] = Regex.run(~r/验证码为 (\d{6})/, rendered["text_body"])

    message_id = rendered["headers"]["Message-ID"]
    html_conn = get(build_conn(), "/dev/mailbox/#{message_id}/html")
    assert html_response(html_conn, 200) =~ code

    verify_conn =
      %{
        recycle(challenge_conn)
        | host: target_conn.host,
          port: target_conn.port,
          scheme: target_conn.scheme
      }
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge_id,
        code: code
      })

    assert %{"status" => "ok"} = api_response(verify_conn, 200)

    session_conn =
      %{
        recycle(verify_conn)
        | host: target_conn.host,
          port: target_conn.port,
          scheme: target_conn.scheme
      }
      |> api_get("/api/v2/browser/session")

    assert Enum.any?(
             api_response(session_conn, 200)["accounts"],
             &(&1["principalUID"] == member.uid)
           )

    clear_conn = post(build_conn(), "/dev/mailbox/clear")
    assert redirected_to(clear_conn, 302) == "/dev/mailbox"
    assert json_response(get(build_conn(), "/dev/mailbox/json"), 200) == %{"data" => []}
  end

  defp accounts_conn(conn) do
    site = URI.parse(AnkoleWeb.PodURL.site_origin(conn))
    host = String.replace_prefix(site.host, "console.", "accounts.")
    %{conn | host: host, port: site.port, scheme: String.to_existing_atom(site.scheme)}
  end
end
