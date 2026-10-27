defmodule AnkoleWeb.PasswordlessAuthenticationTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Principals, Repo}
  alias AnkoleWeb.Session, as: WebSession

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    AppConfigure.Cache.clear_for_test()
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

    assert {:ok, %{console_authenticated: true, challenge_started_at: %DateTime{}}} =
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

    conn =
      conn
      |> init_test_session(%{})
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
        purpose: "site",
        email: proof.subject_id
      })

    %{"challengeID" => id} = api_response(conn, 200)
    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: id,
        code: code
      })

    assert %{"status" => "ok"} = api_response(conn, 200)
    conn = conn |> recycle() |> api_get("/api/v2/browser/session")
    %{"accounts" => accounts} = api_response(conn, 200)

    assert MapSet.new(Enum.map(accounts, & &1["principalUID"])) ==
             MapSet.new(Enum.map(members, & &1.uid))

    [account] = Enum.filter(accounts, &(&1["tenant"]["id"] == first.id))
    reference = account["authenticationRef"]

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: reference,
        tenantID: second.id
      })

    assert %{"podURL" => _} = api_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> put_req_header("x-ankole-authentication", reference)
      |> put_req_header("x-ankole-pod", first.id)
      |> api_get("/api/v2/browser/session")

    assert api_response(conn, 200)["principalUID"] == hd(members).uid
  end

  test "an unfinished setup blocks ordinary OTP login", %{conn: conn} do
    {:ok, _} = AppConfigure.put_global_by_key("setup.completed", false)

    conn =
      conn
      |> init_test_session(%{})
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
        email: "member@example.com"
      })

    assert api_error(conn, 409)
    refute_receive {:email, _}
  end

  test "verified ordinary membership cannot establish a Console session", %{conn: conn} do
    {:ok, _} = AppConfigure.put_global_by_key("setup.completed", true)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "smtp.example.com",
        "from" => "login@example.com"
      })

    {:ok, %{principal: member}} =
      Principals.create_human(%{email: "member@example.com", display_name: "Member"})

    conn =
      conn
      |> init_test_session(%{})
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
        purpose: "console",
        returnTo: "https://evil.example",
        email: "member@example.com"
      })

    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    assert api_error(conn, 403)["code"] == "not_an_admin"
    refute WebSession.site_admin_session(conn)
    refute AuthZ.site_admin?(member.uid)
  end

  test "local mailbox preview serves localized OTP emails in development mode without SMTP settings",
       %{conn: conn} do
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

    providers_conn =
      conn
      |> init_test_session(%{})
      |> api_get("/api/v2/browser/identity-providers", %{purpose: "site"})

    assert Enum.any?(
             api_response(providers_conn, 200)["providers"],
             &(&1["providerID"] == "email_otp")
           )

    challenge_conn =
      providers_conn
      |> recycle()
      |> put_req_header("accept-language", "zh-CN,zh;q=0.9,en;q=0.8")
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
        purpose: "site",
        email: "dev-login@example.com"
      })

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
      challenge_conn
      |> recycle()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge_id,
        code: code
      })

    assert %{"status" => "ok"} = api_response(verify_conn, 200)
    session_conn = verify_conn |> recycle() |> api_get("/api/v2/browser/session")

    assert Enum.any?(
             api_response(session_conn, 200)["accounts"],
             &(&1["principalUID"] == member.uid)
           )

    clear_conn = post(build_conn(), "/dev/mailbox/clear")
    assert redirected_to(clear_conn, 302) == "/dev/mailbox"
    assert json_response(get(build_conn(), "/dev/mailbox/json"), 200) == %{"data" => []}
  end
end
