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
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: :test)

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

    %{"flow" => flow, "challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:delivered_email, %{to: "operator@example.com", text_body: body}}
    assert {:ok, false} = Ankole.Setup.Config.completed?()
    assert {:ok, nil} = AppConfigure.get_by_key("authn.email.mail")
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/setup/email-otp/verifications", %{
        flow: flow,
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

    conn = init_test_session(conn, %{})
    {:ok, conn, transaction} = WebSession.begin_login(conn, :site, %{})

    conn =
      api_post(conn, "/api/v2/browser/sessions/email-otp/challenges", %{
        flow: transaction.id,
        email: proof.subject_id
      })

    %{"challengeID" => id} = api_response(conn, 200)
    assert_receive {:delivered_email, %{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: transaction.id,
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
        flow: Ash.UUIDv7.generate(),
        email: "member@example.com"
      })

    assert api_error(conn, 409)
    refute_receive {:delivered_email, _}
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

    conn = init_test_session(conn, %{})

    {:ok, conn, transaction} =
      WebSession.begin_login(conn, :console, %{"return_to" => "https://evil.example"})

    conn =
      api_post(conn, "/api/v2/browser/sessions/email-otp/challenges", %{
        flow: transaction.id,
        email: "member@example.com"
      })

    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:delivered_email, %{text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: transaction.id,
        challengeID: challenge,
        code: code
      })

    assert api_error(conn, 403)["code"] == "not_an_admin"
    refute WebSession.site_admin_session(conn)
    refute AuthZ.site_admin?(member.uid)
  end
end
