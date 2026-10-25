defmodule AnkoleWeb.PodMembershipAuthenticationTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI, only: [api_response: 2, api_error: 2]
  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Principals, Repo}
  alias Ankole.Principals.HumanAccess
  alias AnkoleWeb.Session, as: WebSession

  setup %{tenant: tenant} do
    AppConfigure.Cache.clear_for_test()
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)

    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.mail", %{
        "server" => "smtp.test",
        "from" => "login@example.org"
      })

    previous = Application.get_env(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: :test)
    Ankole.Authn.RateLimiter.reset_for_test()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, Ankole.Authn.Mailer, previous),
        else: Application.delete_env(:ankole, Ankole.Authn.Mailer)
    end)

    :ok
  end

  test "Pod administrator creates a quota invitation; email verification joins as a guest and consumes its quota",
       %{conn: conn, tenant: tenant} do
    admin = member("admin@example.org")
    {:ok, _} = Repo.transact(fn -> AuthZ.add_pod_admin_in_tx(admin.uid) end)
    conn = login(conn, "admin@example.org", :pod)

    conn =
      conn
      |> api_post("/api/v2/pod/admin/invitations", %{
        membership: "guest",
        maxUses: 1,
        expiresAt: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601()
      })

    %{"url" => url, "code" => invitation_code} = api_response(conn, 200)
    token = url |> URI.parse() |> Map.fetch!(:path) |> String.replace_prefix("/join/", "")

    guest =
      build_conn()
      |> pod_conn(tenant)
      |> init_test_session(%{})
      |> api_get("/api/v2/browser/invitations/" <> invitation_code)

    assert %{"membership" => "guest", "tenantID" => id} = api_response(guest, 200)
    assert id == tenant.id
    guest = guest |> recycle() |> api_post("/api/v2/browser/invitations/#{token}/sessions", %{})
    %{"flow" => flow} = api_response(guest, 200)
    guest = verify(guest, flow, "guest@example.org")
    assert %{"principal_uid" => uid} = WebSession.pod_session(guest)
    assert {:ok, %{membership: :guest}} = Principals.get_principal(uid)
    assert [%{identifier: "guest@example.org"}] = Principals.principal_site_credentials(uid)
    conn = conn |> recycle() |> api_get("/api/v2/pod/admin/invitations")
    assert [%{"used_count" => 1}] = api_response(conn, 200)["invitations"]
    guest = guest |> recycle() |> api_get("/api/v2/browser/invitations/#{token}")
    assert api_error(guest, 410)["code"] == "invitation_unavailable"
  end

  test "a pending member is claimed without another proof, while a recycled email requires a new proof",
       %{conn: conn, tenant: tenant} do
    conn = login(conn, "recycled@example.org", :site)
    ref = WebSession.authentication_reference(conn)
    previous = member("recycled@example.org")
    conn = conn |> recycle() |> api_get("/api/v2/browser/session")
    assert [%{"tenant" => %{"id" => id}}] = api_response(conn, 200)["pendingAccounts"]
    assert id == tenant.id

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: BrowserSessions.encode_reference(ref),
        tenantID: tenant.id
      })

    assert %{"podURL" => _} = api_response(conn, 200)
    actor = Ankole.ActorRef.from_principal(member("operator@example.org"))

    assert {:ok, _} =
             HumanAccess.disable(previous.uid, "departure", actor, "departure-1", :offboarded)

    replacement = member("recycled@example.org")

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: BrowserSessions.encode_reference(ref),
        tenantID: tenant.id
      })

    %{"podURL" => url} = api_response(conn, 200)
    uri = URI.parse(url)
    assert uri.path == "/sessions/new"
    flow = URI.decode_query(uri.query)["flow"]
    assert {:ok, transaction} = WebSession.login_transaction(conn, flow)
    refute Map.has_key?(transaction.request, "invitation_id")
    assert transaction.mode == :add
    assert [] == Principals.principal_site_credentials(replacement.uid)
    conn = verify(recycle(conn), flow, "recycled@example.org")
    assert WebSession.pod_session(conn)["principal_uid"] == replacement.uid
    assert {:ok, %{membership: :member}} = Principals.get_principal(replacement.uid)
    refute replacement.uid == previous.uid
  end

  test "a pending Guest invitation keeps its role and quota through the target Pod SSO login",
       %{conn: conn, tenant: original_tenant} do
    original = member("guest@example.org")
    conn = login(conn, "guest@example.org", :site)
    reference = WebSession.authentication_reference(conn)
    assert {:ok, _} = BrowserSessions.claim_membership(reference, original_tenant.id)
    target = Ankole.DataCase.create_tenant()

    invitation =
      Repo.with_tenant(target.id, fn ->
        admin = member("admin@example.org")

        {:ok, _} =
          Ankole.IdentityProviders.save_provider(
            "company-sso",
            "lark",
            %{"appID" => "cli_guest_invitation", "appSecret" => "fixture"},
            true
          )

        {:ok, _} =
          Ankole.PrincipalsFixtures.create_external_identity(%{
            principal_uid: admin.uid,
            provider: "company-sso",
            external_id: "admin-subject"
          })

        {:ok, settings} = Ankole.Principals.PodAdministration.settings()

        {:ok, _} =
          Ankole.Principals.PodAdministration.update_settings(
            Ankole.AuthZ.Actor.new(admin),
            Map.put(
              settings,
              :loginPolicy,
              Map.put(settings.loginPolicy, "allow_email_otp", false)
            )
          )

        {:ok, created} =
          Principals.create_invitation(admin.uid, %{
            kind: :email,
            invited_email: "guest@example.org",
            membership: :guest,
            expires_at: DateTime.add(DateTime.utc_now(), 3600),
            max_uses: 1
          })

        created.invitation
      end)

    conn = conn |> recycle() |> api_get("/api/v2/browser/session")

    assert [%{"requiresSSO" => true, "invitationID" => id}] =
             api_response(conn, 200)["pendingAccounts"]

    assert id == invitation.id

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: BrowserSessions.encode_reference(reference),
        tenantID: target.id
      })

    %{"podURL" => url} = api_response(conn, 200)
    uri = URI.parse(url)
    assert uri.host == URI.parse(AnkoleWeb.PodURL.origin(conn, target)).host
    assert uri.path == "/sessions/new"
    flow = URI.decode_query(uri.query)["flow"]
    assert {:ok, transaction} = WebSession.login_transaction(conn, flow)
    assert transaction.tenant_id == target.id
    assert transaction.mode == :add
    assert transaction.request["invitation_id"] == invitation.id

    assert BrowserSessions.identity(reference, original_tenant.id)["principal_uid"] ==
             original.uid

    conn =
      conn
      |> recycle()
      |> pod_conn(target)
      |> api_get("/api/v2/browser/identity-providers?flow=" <> flow)

    assert [%{"providerID" => "company-sso", "kind" => "oidc"}] =
             api_response(conn, 200)["providers"]

    Repo.with_tenant(target.id, fn ->
      assert {:ok, %{membership: :guest, used_count: 0}} =
               Principals.invitation_for_login(invitation.id)

      refute Enum.any?(
               Principals.list_site_credentials("email_otp", "guest@example.org"),
               &(&1.tenant_id == target.id)
             )
    end)
  end

  test "a member replaces the login email only after verifying the new address, then exits only this Pod",
       %{conn: conn} do
    person = member("original@example.org")
    other_tenant = Ankole.DataCase.create_tenant()

    other =
      Repo.with_tenant(other_tenant.id, fn ->
        principal = member("original@example.org")

        {:ok, _} =
          Repo.transact(fn ->
            Principals.bind_site_credential_in_tx(principal.uid, %{
              provider_id: "email_otp",
              subject_id: "original@example.org",
              verified_email: "original@example.org"
            })
          end)

        principal
      end)

    conn = login(conn, "original@example.org", :pod)
    original_ref = WebSession.authentication_reference(conn)
    conn = conn |> api_post("/api/v2/pod/me/email/challenges", %{email: "new@example.org"})
    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:delivered_email, %{to: "new@example.org", text_body: body}}

    assert [%{identifier: "original@example.org"}] =
             Principals.principal_site_credentials(person.uid)

    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> api_post("/api/v2/pod/me/email/verifications", %{challengeID: challenge, code: code})

    assert %{"ok" => true, "authenticationRef" => new_ref, "csrfToken" => csrf} =
             api_response(conn, 200)

    assert is_binary(csrf)
    assert new_ref != BrowserSessions.encode_reference(original_ref)
    assert [%{identifier: "new@example.org"}] = Principals.principal_site_credentials(person.uid)
    assert WebSession.pod_session(conn)["principal_uid"] == person.uid

    conn =
      conn
      |> recycle()
      |> put_req_header("x-ankole-authentication", new_ref)
      |> api_get("/api/v2/pod/me")

    assert api_response(conn, 200)["credentials"]
           |> Enum.any?(&(&1["identifier"] == "new@example.org"))

    conn =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("x-ankole-authentication", new_ref)
      |> put_req_header("x-csrf-token", csrf)
      |> api_delete("/api/v2/pod/me/membership")

    assert %{"ok" => true} = api_response(conn, 200)
    assert [] == Principals.principal_site_credentials(person.uid)
    assert {:ok, %{status: :disabled} = principal} = Principals.get_principal(person.uid)
    assert %{human_user: %{email: nil}} = Ankole.Ash.load!(principal, [:human_user])
    assert BrowserSessions.identity(original_ref, other_tenant.id)["principal_uid"] == other.uid
    conn = conn |> recycle() |> api_get("/api/v2/browser/session")
    assert Enum.any?(api_response(conn, 200)["accounts"], &(&1["principalUID"] == other.uid))
  end

  test "email reauthentication preserves the console, pinned Pod reference and RP session", %{
    conn: conn,
    tenant: tenant
  } do
    admin = member("renew@example.org")
    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(admin.uid)
    conn = login(conn, "renew@example.org", :console)
    original_ref = WebSession.authentication_reference(conn)
    {:ok, original} = BrowserSessions.get_authentication(original_ref)
    assert original.console_authenticated

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Browser reauthentication",
        enabled: true,
        type: "public",
        redirect_uris: ["https://client.example/callback"],
        scopes: ["openid"]
      })

    {:ok, rp} =
      Ankole.OIDC.Sessions.ensure(
        client.id,
        BrowserSessions.identity(original_ref, tenant.id),
        "openid"
      )

    conn = login(recycle(conn), "renew@example.org", :site)
    assert WebSession.authentication_reference(conn) == original_ref
    {:ok, renewed} = BrowserSessions.get_authentication(original_ref)
    assert renewed.console_authenticated
    assert renewed.csrf_token == original.csrf_token
    assert BrowserSessions.authentication(original_ref, :console)["principal_uid"] == admin.uid
    assert {:ok, _} = Ankole.OIDC.Sessions.validate(rp.id, client.id, admin.uid, "openid")

    conn =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(original_ref))
      |> api_get("/api/v2/pod/me")

    assert api_response(conn, 200)["displayName"] == admin.display_name
  end

  test "the last Pod administrator cannot leave or tighten policy without a usable permitted binding",
       %{conn: conn} do
    admin = member("admin@example.org")
    {:ok, _} = Repo.transact(fn -> AuthZ.add_pod_admin_in_tx(admin.uid) end)
    conn = login(conn, "admin@example.org", :pod)
    exit_conn = api_delete(conn, "/api/v2/pod/me/membership")
    assert api_error(exit_conn, 400)["code"] == "last_active_human_admin"
    assert {:ok, %{status: :active}} = Principals.get_principal(admin.uid)
    conn = conn |> recycle() |> api_get("/api/v2/pod/admin/settings")
    settings = api_response(conn, 200)
    policy = Map.put(settings["loginPolicy"], "require_sso_for_members", true)

    conn =
      conn
      |> recycle()
      |> api_put("/api/v2/pod/admin/settings", %{
        displayName: settings["displayName"],
        allowExternalGuests: settings["allowExternalGuests"],
        loginPolicy: policy
      })

    assert api_error(conn, 400)["code"] == "administrator_lockout"
    assert {:ok, %{"require_sso_for_members" => false}} = Ankole.Principals.PodLoginPolicy.get()
  end

  test "an ordinary member has no Pod administration or site Console authority", %{conn: conn} do
    member("member@example.org")
    conn = login(conn, "member@example.org", :pod)
    assert conn |> api_get("/api/v2/pod/admin/settings") |> api_error(403)
    refute AuthZ.site_admin?(WebSession.pod_session(conn)["principal_uid"])
  end

  for method <- [:get, :post, :put, :delete] do
    def unquote(:"api_#{method}")(conn, path, params \\ nil) do
      Repo.with_tenant(Repo.tenant_id!(), fn ->
        url = AnkoleWeb.Plugs.RequestHost.origin(conn) <> path
        AnkoleWeb.PodAPI.request(conn, unquote(method), url, params)
      end)
    end
  end

  defp member(email) do
    {:ok, %{principal: principal}} = Principals.create_human(%{email: email, display_name: email})
    principal
  end

  defp login(conn, email, purpose) do
    conn =
      if purpose == :pod do
        {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
        pod_conn(conn, tenant)
      else
        site_conn(conn)
      end

    conn = api_get(conn, "/api/v2/browser/session")
    session = get_session(conn)
    conn = conn |> recycle() |> init_test_session(session)
    {:ok, conn, transaction} = WebSession.begin_login(conn, purpose, %{}, mode: :add)
    verify(conn, transaction.id, email)
  end

  defp verify(conn, flow, email) do
    conn =
      api_post(conn, "/api/v2/browser/sessions/email-otp/challenges", %{flow: flow, email: email})

    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:delivered_email, %{to: ^email, text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    conn =
      conn
      |> recycle()
      |> put_req_header("x-ankole-pod", Repo.tenant_id!())
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: flow,
        challengeID: challenge,
        code: code
      })

    assert %{"status" => "ok"} = api_response(conn, 200)
    conn
  end
end
