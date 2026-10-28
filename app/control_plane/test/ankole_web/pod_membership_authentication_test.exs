defmodule AnkoleWeb.PodMembershipAuthenticationTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI, only: [api_response: 2, api_error: 2]
  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Principals, Repo}
  alias Ankole.Principals.HumanAccess
  alias AnkoleWeb.Session, as: WebSession

  @host_policy Application.compile_env(:ankole, :host_policy)

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
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Test)
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

    assert %{"membership" => "guest", "tenantID" => id, "emailLoginURL" => email_login_url} =
             api_response(guest, 200)

    assert id == tenant.id

    if @host_policy do
      assert String.starts_with?(URI.parse(email_login_url).host, "accounts.")
    else
      assert URI.parse(email_login_url).host ==
               URI.parse(AnkoleWeb.PodURL.origin(conn, tenant)).host
    end

    guest =
      guest
      |> recycle()
      |> verify_for_tenant(tenant, "guest@example.org", %{invitationToken: token})

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
    seed_tenant = Ankole.DataCase.create_tenant()
    Repo.with_tenant(seed_tenant.id, fn -> member("recycled@example.org") end)

    conn =
      Repo.with_tenant(seed_tenant.id, fn ->
        login(conn, "recycled@example.org", :pod)
      end)

    ref = WebSession.authentication_reference(conn)
    previous = member("recycled@example.org")
    session_conn = session_origin_conn(conn, seed_tenant) |> api_get("/api/v2/browser/session")

    assert [%{"tenant" => %{"id" => id}}] = api_response(session_conn, 200)["pendingAccounts"]
    assert id == tenant.id

    conn =
      session_origin_conn(session_conn, seed_tenant)
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
      session_origin_conn(conn, seed_tenant)
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: BrowserSessions.encode_reference(ref),
        tenantID: tenant.id
      })

    %{"podURL" => url} = api_response(conn, 200)
    uri = URI.parse(url)
    assert uri.path == "/sessions/new"

    if @host_policy do
      assert String.starts_with?(uri.host, "accounts.")

      assert URI.decode_query(uri.query) == %{
               "tenant_id" => tenant.id,
               "switch" => "1",
               "prompt" => "login"
             }
    else
      assert URI.decode_query(uri.query) == %{"switch" => "1", "prompt" => "login"}
    end

    assert [] == Principals.principal_site_credentials(replacement.uid)
    conn = conn |> recycle() |> verify_for_tenant(tenant, "recycled@example.org", %{})
    assert WebSession.pod_session(conn)["principal_uid"] == replacement.uid
    assert {:ok, %{membership: :member}} = Principals.get_principal(replacement.uid)
    refute replacement.uid == previous.uid
  end

  test "a pending Guest invitation keeps its role and quota through the target Pod SSO login",
       %{conn: conn, tenant: original_tenant} do
    original = member("guest@example.org")
    conn = login(conn, "guest@example.org", :pod)
    reference = WebSession.authentication_reference(conn)

    assert BrowserSessions.identity(reference, original_tenant.id)["principal_uid"] ==
             original.uid

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

    conn = session_origin_conn(conn, original_tenant) |> api_get("/api/v2/browser/session")

    assert [%{"requiresSSO" => true, "invitationID" => id}] =
             api_response(conn, 200)["pendingAccounts"]

    assert id == invitation.id

    conn =
      session_origin_conn(conn, original_tenant)
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: BrowserSessions.encode_reference(reference),
        tenantID: target.id
      })

    %{"podURL" => url} = api_response(conn, 200)
    uri = URI.parse(url)
    assert uri.host == URI.parse(AnkoleWeb.PodURL.origin(conn, target)).host
    query = URI.decode_query(uri.query)

    if @host_policy do
      assert uri.path == "/sessions/oidc/company-sso/authorization"
      assert query["prompt"] == "login"
    else
      assert uri.path == "/sessions/new"
      assert query["switch"] == "1"
    end

    sealed_invitation = Map.fetch!(query, "invitation")

    assert WebSession.unseal_membership_invitation(conn, sealed_invitation, target.id) ==
             {:ok, invitation.id}

    assert BrowserSessions.identity(reference, original_tenant.id)["principal_uid"] ==
             original.uid

    providers_conn =
      if @host_policy do
        conn
        |> recycle()
        |> accounts_conn()
        |> api_get(
          "/api/v2/browser/identity-providers?" <>
            URI.encode_query(%{
              "tenant_id" => target.id,
              "switch" => "1",
              "invitation" => sealed_invitation
            })
        )
      else
        conn
        |> recycle()
        |> pod_conn(target)
        |> api_get(
          "/api/v2/browser/identity-providers?" <>
            URI.encode_query(%{"switch" => "1", "invitation" => sealed_invitation})
        )
      end

    oidc_providers =
      Enum.filter(api_response(providers_conn, 200)["providers"], &(&1["kind"] == "oidc"))

    assert [%{"providerID" => "company-sso", "kind" => "oidc"}] = oidc_providers

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
    assert_receive {:email, %Swoosh.Email{to: [{_, "new@example.org"}], text_body: body}}

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
    assert {:ok, changed} = Principals.get_principal(person.uid)
    assert Ankole.Ash.load!(changed, [:human_user]).human_user.email == "new@example.org"

    assert [] ==
             Principals.SiteCredentials.pending_memberships(%{
               provider_id: "email_otp",
               subject_id: "original@example.org",
               verified_email: "original@example.org"
             })
             |> Enum.filter(&(&1.tenant_id == person.tenant_id))

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

  test "Pod administrators cannot create an unclaimable member without email", %{conn: conn} do
    admin = member("member-admin@example.org")
    {:ok, _} = Repo.transact(fn -> AuthZ.add_pod_admin_in_tx(admin.uid) end)
    conn = login(conn, "member-admin@example.org", :pod)
    conn = api_post(conn, "/api/v2/pod/admin/members", %{displayName: "No email"})
    assert api_error(conn, 400)
  end

  test "a member can change their own display name through personal settings", %{conn: conn} do
    person = member("profile@example.org")
    conn = login(conn, "profile@example.org", :pod)

    conn = conn |> api_patch("/api/v2/pod/me", %{displayName: "Alice"})
    assert api_response(conn, 200) == %{"displayName" => "Alice"}
    assert {:ok, %{display_name: "Alice"}} = Principals.get_principal(person.uid)
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

    conn = login(recycle(conn), "renew@example.org", :pod)
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
        defaultLocale: settings["defaultLocale"],
        allowExternalGuests: settings["allowExternalGuests"],
        loginPolicy: policy
      })

    assert api_error(conn, 400)["code"] == "administrator_lockout"
    assert {:ok, %{"require_sso_for_members" => false}} = Ankole.Principals.PodLoginPolicy.get()
  end

  test "Pod administrators read and update their Pod's defaultLocale without affecting other Pods",
       %{conn: conn} do
    other_tenant =
      Ankole.DataCase.create_tenant(%{slug: "other-locale-pod", display_name: "Other"})

    admin = member("locale-admin@example.org")
    {:ok, _} = Repo.transact(fn -> AuthZ.add_pod_admin_in_tx(admin.uid) end)
    conn = login(conn, "locale-admin@example.org", :pod)

    settings = conn |> api_get("/api/v2/pod/admin/settings") |> api_response(200)
    assert settings["defaultLocale"] == "en-US"

    rejected =
      conn
      |> recycle()
      |> api_put("/api/v2/pod/admin/settings", %{
        displayName: settings["displayName"],
        defaultLocale: "fr-FR",
        allowExternalGuests: settings["allowExternalGuests"],
        loginPolicy: settings["loginPolicy"]
      })

    assert api_error(rejected, 422)["code"] == "unavailable_locale"

    updated =
      conn
      |> recycle()
      |> api_put("/api/v2/pod/admin/settings", %{
        displayName: settings["displayName"],
        defaultLocale: "ko-KR",
        allowExternalGuests: settings["allowExternalGuests"],
        loginPolicy: settings["loginPolicy"]
      })
      |> api_response(200)

    assert updated["defaultLocale"] == "ko-KR"
    assert Ankole.I18n.configured_default_locale() == {:ok, "ko-KR"}

    Repo.with_tenant(other_tenant.id, fn ->
      assert Ankole.I18n.configured_default_locale() == {:ok, "en-US"}
    end)
  end

  test "Pod provider creation cannot overwrite a connection and editing keeps its identity", %{
    conn: conn
  } do
    admin = member("provider-admin@example.org")
    {:ok, _} = Repo.transact(fn -> AuthZ.add_pod_admin_in_tx(admin.uid) end)
    conn = login(conn, "provider-admin@example.org", :pod)
    path = "/api/v2/pod/admin/identity-providers/company"

    attrs = %{
      adapter_id: "lark",
      enabled: true,
      config: %{"appID" => "cli_company", "appSecret" => "company-secret"}
    }

    response = api_post(conn, path, attrs)
    assert %{"ok" => true} = api_response(response, 200)

    replacement = %{
      attrs
      | config: %{"appID" => "cli_replacement", "appSecret" => "replacement-secret"}
    }

    duplicate = api_post(recycle(response), path, replacement)
    assert api_error(duplicate, 409)["code"] == "identity_provider_exists"
    assert {:ok, original} = AppConfigure.get_by_key("principals.identity_providers.lark.company")
    assert original["appID"] == "cli_company"
    assert original["appSecret"] == "company-secret"

    updated = api_put(recycle(duplicate), path, replacement)
    assert %{"ok" => true} = api_response(updated, 200)
    assert {:ok, saved} = AppConfigure.get_by_key("principals.identity_providers.lark.company")
    assert saved["appID"] == "cli_replacement"
    assert saved["appSecret"] == "replacement-secret"

    missing = api_put(recycle(updated), path <> "-missing", attrs)
    assert api_error(missing, 404)["code"] == "not_found"
  end

  test "an ordinary member has no Pod administration or site Console authority", %{conn: conn} do
    member("member@example.org")
    conn = login(conn, "member@example.org", :pod)
    assert conn |> api_get("/api/v2/pod/admin/settings") |> api_error(403)
    refute AuthZ.site_admin?(WebSession.pod_session(conn)["principal_uid"])
  end

  test "directed email invitations silently skip OTP delivery for non-invited addresses", %{
    conn: conn,
    tenant: tenant
  } do
    admin = member("invite-admin@example.org")
    {:ok, _} = Repo.transact(fn -> AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, created} =
      Principals.create_invitation(admin.uid, %{
        kind: :email,
        invited_email: "invited-only@example.org",
        membership: :guest,
        expires_at: DateTime.add(DateTime.utc_now(), 3600),
        max_uses: 1
      })

    target_conn = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, tenant)

    base_params =
      if @host_policy,
        do: %{tenantID: tenant.id, invitationToken: created.code},
        else: %{invitationToken: created.code}

    mismatched =
      target_conn
      |> init_test_session(%{})
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(base_params, :email, "wrong-person@example.org")
      )

    %{"challengeID" => bad_challenge} = api_response(mismatched, 200)
    refute_receive {:email, _}

    rejected =
      %{
        recycle(mismatched)
        | host: target_conn.host,
          port: target_conn.port,
          scheme: target_conn.scheme
      }
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: bad_challenge,
        code: "123456"
      })

    assert api_error(rejected, 401)["code"] == "invalid_code"

    joined =
      conn
      |> init_test_session(%{})
      |> verify_for_tenant(tenant, "invited-only@example.org", %{invitationToken: created.code})

    assert %{"principal_uid" => uid} = WebSession.pod_session(joined)
    assert {:ok, %{membership: :guest}} = Principals.get_principal(uid)
  end

  for method <- [:get, :post, :put, :patch, :delete] do
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

  defp accounts_conn(conn) do
    site = URI.parse(AnkoleWeb.PodURL.site_origin(conn))
    host = String.replace_prefix(site.host, "console.", "accounts.")
    %{conn | host: host, port: site.port, scheme: String.to_existing_atom(site.scheme)}
  end

  defp session_origin_conn(conn, tenant) do
    target = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, tenant)
    %{recycle(conn) | host: target.host, port: target.port, scheme: target.scheme}
  end

  defp login(conn, email, :pod) do
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    target = if @host_policy, do: accounts_conn(conn), else: pod_conn(conn, tenant)
    conn = api_get(target, "/api/v2/browser/session")
    session = get_session(conn)

    conn =
      %{recycle(conn) | host: target.host, port: target.port, scheme: target.scheme}
      |> init_test_session(session)

    verify_for_tenant(conn, tenant, email, %{})
  end

  defp login(conn, email, purpose) do
    conn = site_conn(conn)
    conn = api_get(conn, "/api/v2/browser/session")
    session = get_session(conn)

    conn =
      %{recycle(conn) | host: conn.host, port: conn.port, scheme: conn.scheme}
      |> init_test_session(session)

    verify(conn, email, %{purpose: Atom.to_string(purpose)})
  end

  defp verify_for_tenant(conn, tenant, email, extra) do
    if @host_policy do
      target = accounts_conn(conn)

      conn =
        %{conn | host: target.host, port: target.port, scheme: target.scheme}
        |> verify(email, Map.merge(extra, %{purpose: "site", tenantID: tenant.id}))

      pod_conn(%{recycle(conn) | scheme: conn.scheme, port: conn.port}, tenant)
      |> delete_req_header("accept")
      |> get("/")
    else
      conn
      |> pod_conn(tenant)
      |> verify(email, extra)
    end
  end

  defp verify(conn, email, extra) do
    host = conn.host
    port = conn.port
    scheme = conn.scheme

    conn =
      api_post(
        conn,
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(extra, :email, email)
      )

    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:email, %Swoosh.Email{to: [{_, ^email}], text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    conn =
      %{recycle(conn) | host: host, port: port, scheme: scheme}
      |> put_req_header("x-ankole-pod", Repo.tenant_id!())
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    assert %{"status" => "ok"} = api_response(conn, 200)
    conn
  end
end
