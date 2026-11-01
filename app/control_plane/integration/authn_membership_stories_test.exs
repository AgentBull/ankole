defmodule Ankole.Authn.MembershipStoriesTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  import Ankole.PrincipalsFixtures
  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Principals, Repo}
  alias Ankole.Authn.{Domain, SMTPFixture}
  alias Ankole.Principals.{HumanAccess, PodLoginPolicy}
  alias AnkoleWeb.Session, as: WebSession

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    {:ok, _} = AppConfigure.put_global_by_key("setup.completed", true)
    smtp = SMTPFixture.start(self())
    on_exit(fn -> SMTPFixture.stop(smtp) end)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "127.0.0.1",
        "port" => smtp.port,
        "ssl" => true,
        "from" => "login@ankole.test",
        "cacertfile" => smtp.ca_path
      })

    Ankole.Authn.RateLimiter.reset_for_test()
    :ok
  end

  test "different account codes both complete through the browser API and real SMTP", %{
    conn: conn,
    tenant: tenant
  } do
    first = human_fixture(%{email: "independent-a@example.test"}).principal
    second = human_fixture(%{email: "independent-b@example.test"}).principal

    page =
      conn |> pod_conn(tenant) |> get("/sessions/new") |> follow_login() |> browser_api_conn()

    tenant_extra = if @host_policy, do: %{tenantID: tenant.id}, else: %{}

    sent_first =
      api_post(
        page,
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(tenant_extra, :email, "independent-a@example.test")
      )

    first_id = api_response(sent_first, 201)["challengeID"]
    first_code = delivered_code("independent-a@example.test")

    sent_second =
      sent_first
      |> recycle_api()
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(tenant_extra, :email, "independent-b@example.test")
      )

    second_id = api_response(sent_second, 201)["challengeID"]
    second_code = delivered_code("independent-b@example.test")

    verified_first =
      sent_second
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: first_id,
        code: first_code
      })

    assert %{"returnTo" => _} = api_response(verified_first, 201)
    first_ref = WebSession.authentication_reference(verified_first)

    verified_second =
      verified_first
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: second_id,
        code: second_code
      })

    assert %{"returnTo" => _} = api_response(verified_second, 201)
    second_ref = WebSession.authentication_reference(verified_second)
    assert BrowserSessions.identity(first_ref, tenant.id)["principal_uid"] == first.uid
    assert BrowserSessions.identity(second_ref, tenant.id)["principal_uid"] == second.uid
  end

  test "a code sent before browser logout establishes a new session for the same member", %{
    conn: conn,
    tenant: tenant
  } do
    member = human_fixture(%{email: "returning-member@example.test"}).principal
    {signed_in, old_ref} = pod_login(conn, tenant, "returning-member@example.test")

    login_page =
      signed_in
      |> put_req_header("accept", "text/html")
      |> get("/sessions/new?switch=1")
      |> follow_login()
      |> browser_api_conn()

    tenant_extra = if @host_policy, do: %{tenantID: tenant.id}, else: %{}

    sent =
      login_page
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(tenant_extra, :email, "returning-member@example.test")
      )

    challenge_id = api_response(sent, 201)["challengeID"]
    code = delivered_code("returning-member@example.test")

    signed_out =
      sent
      |> recycle_api()
      |> put_req_header("x-csrf-token", List.first(get_req_header(signed_in, "x-csrf-token")))
      |> api_delete("/api/v2/browser/session")

    assert %{"ok" => true} = api_response(signed_out, 200)
    refute BrowserSessions.identity(old_ref, tenant.id)

    verified =
      signed_out
      |> recycle_api()
      |> put_req_header("x-csrf-token", List.first(get_req_header(login_page, "x-csrf-token")))
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge_id,
        code: code
      })

    assert %{"returnTo" => _} = api_response(verified, 201)
    new_ref = WebSession.authentication_reference(verified)
    assert BrowserSessions.identity(new_ref, tenant.id)["principal_uid"] == member.uid
    refute BrowserSessions.identity(old_ref, tenant.id)
    refute new_ref == old_ref
  end

  test "an old site proof claims an ordinary new membership but cannot claim a recycled email", %{
    tenant: tenant
  } do
    email = "reassigned@example.test"
    initial = site_login(email)
    first = human_fixture(%{email: email}).principal
    reference = BrowserSessions.reference(initial.authentication)
    assert {:ok, %{uid: uid}} = BrowserSessions.claim_membership(reference, tenant.id)
    assert uid == first.uid
    assert BrowserSessions.identity(reference, tenant.id)["principal_uid"] == first.uid
    assert {:ok, _} = HumanAccess.disable(first.uid, "departure", nil, "departure-1", :offboarded)
    second = human_fixture(%{email: email}).principal

    assert {:error, :reauthentication_required} =
             BrowserSessions.claim_membership(reference, tenant.id)

    assert [] == Principals.principal_site_credentials(second.uid)
    refute BrowserSessions.identity(reference, tenant.id)
    fresh = site_login(email)
    reference = BrowserSessions.reference(fresh.authentication)
    assert {:ok, %{uid: uid}} = BrowserSessions.claim_membership(reference, tenant.id)
    assert uid == second.uid
    assert BrowserSessions.identity(reference, tenant.id)["principal_uid"] == second.uid
    assert {:ok, %{status: :disabled}} = Principals.get_principal(first.uid)
  end

  test "both authoritative Lark contact addresses discover the same pending Human", %{
    tenant: tenant
  } do
    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_contacts", "appSecret" => "fixture"},
               true
             )

    assert {:ok, observed} =
             Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user("lark-main", %{
               "user_id" => "stable-user",
               "enterprise_email" => "employee@corp.test",
               "email" => "personal@example.test"
             })

    uid = observed.principal.uid

    for email <- ["employee@corp.test", "personal@example.test"] do
      login = site_login(email)
      proof = Map.from_struct(login.authentication)
      assert [%{uid: ^uid}] = Principals.pending_site_memberships(proof)

      assert [%{provider: "email", principal_uid: ^uid}] =
               Principals.list_external_identities!(
                 query: [filter: [provider: "email", external_id: email]]
               )

      assert {:ok, %{uid: ^uid}} =
               BrowserSessions.claim_membership(
                 BrowserSessions.reference(login.authentication),
                 tenant.id
               )

      # The Lark login remains available when the personal email is removed.
      [credential] = Principals.principal_site_credentials(uid)

      assert {:ok, _} =
               Repo.transact(fn ->
                 Principals.unbind_site_credential_in_tx(uid, credential.id)
               end)
    end

    assert length(Principals.list_principals!(query: [filter: [type: :human]])) == 1
  end

  test "an invitation enforces its guest role and quota under the live member SSO policy", %{
    tenant: tenant
  } do
    admin = human_fixture().principal

    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "company-sso",
               "lark",
               %{"appID" => "cli_policy", "appSecret" => "fixture"},
               true
             )

    assert {:ok, _} =
             create_external_identity(%{
               principal_uid: admin.uid,
               provider: "company-sso",
               external_id: "admin-subject"
             })

    {:ok, policy} = PodLoginPolicy.get()

    assert {:ok, _} =
             update_policy(admin, Map.put(policy, "require_sso_for_members", true))

    assert {:ok, invitation} =
             Principals.create_invitation(admin.uid, %{
               kind: :link,
               invited_email: nil,
               membership: :guest,
               expires_at: DateTime.add(DateTime.utc_now(), 3600),
               max_uses: 1
             })

    login = site_login("visitor@example.test")
    reference = BrowserSessions.reference(login.authentication)

    assert {:ok, guest} =
             BrowserSessions.accept_invitation(reference, tenant.id, invitation.invitation.id)

    assert guest.membership == :guest
    assert BrowserSessions.identity(reference, tenant.id)["principal_uid"] == guest.uid
    assert {:error, :invitation_unavailable} = Principals.locate_invitation(invitation.code)

    assert {:error, :invitation_unavailable} =
             BrowserSessions.accept_invitation(reference, tenant.id, invitation.invitation.id)

    assert {:ok, _} = AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)
    refute BrowserSessions.identity(reference, tenant.id)
    assert Repo.get!(Ankole.Principals.Invitation, invitation.invitation.id).used_count == 1

    assert [] ==
             AuthZ.list_current_groups_for_principal(guest.uid)
             |> elem(1)
             |> Enum.filter(&(&1.name == "pod_admin"))
  end

  test "the current Pod policy immediately stops browser and offline RP use of a personal proof",
       %{tenant: tenant} do
    person = human_fixture(%{email: "member@example.test"}).principal
    login = site_login("member@example.test")
    reference = BrowserSessions.reference(login.authentication)
    assert {:ok, _} = BrowserSessions.claim_membership(reference, tenant.id)

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Policy client",
        enabled: true,
        type: "public",
        redirect_uris: ["https://rp.example.test/callback"],
        scopes: ["openid", "offline_access"]
      })

    proof = BrowserSessions.identity(reference, tenant.id)
    assert {:ok, session} = Ankole.OIDC.Sessions.ensure(client.id, proof, "openid offline_access")

    assert {:ok, _} =
             Ankole.OIDC.Sessions.validate(
               session.id,
               client.id,
               person.uid,
               "openid offline_access"
             )

    {:ok, policy} = PodLoginPolicy.get()
    tightened = Map.put(policy, "require_sso_for_members", true)
    assert {:error, :administrator_lockout} = update_policy(person, tightened)

    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "company-sso",
               "lark",
               %{"appID" => "cli_live_policy", "appSecret" => "fixture"},
               true
             )

    assert {:ok, _} =
             create_external_identity(%{
               principal_uid: person.uid,
               provider: "company-sso",
               external_id: "member-subject"
             })

    assert {:ok, _} = update_policy(person, tightened)
    refute BrowserSessions.identity(reference, tenant.id)

    assert {:error, :authorization_revoked} =
             Ankole.OIDC.Sessions.validate(
               session.id,
               client.id,
               person.uid,
               "openid offline_access"
             )

    assert {:ok, _} = update_policy(person, policy)
    assert BrowserSessions.identity(reference, tenant.id)["principal_uid"] == person.uid
  end

  test "the real member API replaces a verified email and refuses stale proof and a locked policy",
       %{conn: conn, tenant: tenant} do
    person = human_fixture(%{email: "original@example.test"}).principal
    {conn, reference} = pod_login(conn, tenant, "original@example.test")
    sent = api_post(conn, "/api/v2/pod/me/email/challenges", %{email: "new-login@example.test"})
    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code("new-login@example.test")

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/pod/me/email/verifications", %{challengeID: challenge, code: code})

    assert %{"ok" => true, "authenticationRef" => encoded_reference, "csrfToken" => csrf} =
             api_response(verified, 201)

    assert [%{identifier: "new-login@example.test", provider: "email_otp"}] =
             Principals.principal_site_credentials(person.uid)

    assert Repo.get_by!(Ankole.Principals.HumanUser, principal_uid: person.uid).email ==
             "new-login@example.test"

    # The old login address stops authorizing this Pod after its replacement.
    refute BrowserSessions.identity(reference, tenant.id)
    conn = verified
    reference = WebSession.authentication_reference(verified)
    assert BrowserSessions.identity(reference, tenant.id)["principal_uid"] == person.uid
    {:ok, authentication} = BrowserSessions.get_authentication(reference)

    Repo.update!(
      Ecto.Changeset.change(authentication,
        authenticated_at: DateTime.add(DateTime.utc_now(), -901)
      )
    )

    refused =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-authentication", encoded_reference)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/pod/me/email/challenges", %{email: "stale@example.test"})

    assert api_error(refused, 403)["code"] == "reauthentication_required"
    {:ok, policy} = PodLoginPolicy.get()

    assert {:ok, _} =
             update_policy(
               person,
               Map.put(policy, "allow_member_credential_change", false)
             )

    refused =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-authentication", encoded_reference)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/pod/me/email/challenges", %{email: "locked@example.test"})

    assert api_error(refused, 403)["code"] == "credential_change_disabled"
    refute_receive {:smtp_message, _, _, _}, 50
  end

  test "account settings starts a member-bound reauthentication with a fresh delivered code", %{
    conn: conn,
    tenant: tenant
  } do
    person = human_fixture(%{email: "reauth@example.test"}).principal
    {conn, _} = pod_login(conn, tenant, "reauth@example.test")

    entry = api_post(conn, "/api/v2/pod/me/reauthentication", %{})
    path = api_response(entry, 201)["loginURL"]
    reauth = URI.decode_query(URI.parse(path).query)["reauth"]

    page =
      entry |> recycle() |> put_req_header("accept", "text/html") |> get(path) |> follow_login()

    conn = browser_api_conn(page)

    provider_query =
      if @host_policy,
        do: %{"tenant_id" => tenant.id, "reauth" => reauth},
        else: %{"reauth" => reauth}

    providers = api_get(conn, "/api/v2/browser/identity-providers", provider_query)
    assert api_response(providers, 200)["identities"] == []

    reauth_payload =
      if @host_policy do
        %{tenantID: tenant.id, reauth: reauth, returnTo: "/me", email: "reauth@example.test"}
      else
        %{reauth: reauth, returnTo: "/me", email: "reauth@example.test"}
      end

    sent =
      providers
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", reauth_payload)

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code("reauth@example.test")

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    return_to = api_response(verified, 201)["returnTo"]
    assert URI.parse(return_to).path == "/me"

    entered =
      verified
      |> recycle()
      |> delete_req_header("accept")
      |> get(return_to)

    assert WebSession.pod_session(entered)["principal_uid"] == person.uid
  end

  test "reauthentication pins the initiating tab and rejects another Human without reviving its code",
       %{
         conn: conn,
         tenant: tenant
       } do
    owner = human_fixture(%{email: "pinned-owner@example.test"}).principal
    other = human_fixture(%{email: "other-member@example.test"}).principal
    {owner_conn, owner_ref} = pod_login(conn, tenant, "pinned-owner@example.test")
    [owner_csrf] = get_req_header(owner_conn, "x-csrf-token")

    entry =
      owner_conn
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> get("/sessions/new?switch=1")
      |> follow_login()

    tenant_extra = if @host_policy, do: %{tenantID: tenant.id}, else: %{}

    {other_conn, _, _} =
      verify_email_on_page(entry, "other-member@example.test", tenant_extra)

    assert %{"returnTo" => _} = api_response(other_conn, 201)
    other_ref = WebSession.authentication_reference(other_conn)
    assert BrowserSessions.identity(other_ref, tenant.id)["principal_uid"] == other.uid

    pinned =
      other_conn
      |> recycle_api()
      |> pod_conn(tenant)
      |> put_req_header("origin", AnkoleWeb.PodURL.origin(other_conn, tenant))
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(owner_ref))
      |> put_req_header("x-csrf-token", owner_csrf)
      |> api_post("/api/v2/pod/me/reauthentication", %{})

    path = api_response(pinned, 201)["loginURL"]
    reauth = URI.decode_query(URI.parse(path).query)["reauth"]
    assert {:ok, ticket} = WebSession.unseal_reauthentication(pinned, reauth, tenant.id)
    assert ticket.authentication_id == owner_ref["id"]
    assert ticket.uid == owner.uid

    reauth_page =
      pinned
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> get(path)
      |> follow_login()

    denied_selection =
      reauth_page
      |> browser_api_conn()
      |> api_post(
        "/api/v2/browser/sessions/identity-selection",
        Map.merge(tenant_extra, %{
          reauth: reauth,
          returnTo: "/me",
          authenticationRef: BrowserSessions.encode_reference(other_ref)
        })
      )

    assert api_error(denied_selection, 403)["code"] == "reauthentication_required"

    silent_other =
      reauth_page
      |> browser_api_conn()
      |> api_post(
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.merge(tenant_extra, %{
          reauth: reauth,
          returnTo: "/me",
          email: "other-member@example.test"
        })
      )

    challenge = api_response(silent_other, 201)["challengeID"]
    refute_receive {:smtp_message, _, ["other-member@example.test"], _}, 100
    assert is_nil(Repo.get!(Ankole.Authn.Challenge, challenge).secret_digest)

    rejected =
      silent_other
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: "000000"
      })

    assert api_error(rejected, 401)["code"] == "invalid_code"
    assert BrowserSessions.identity(owner_ref, tenant.id)["principal_uid"] == owner.uid
    assert BrowserSessions.identity(other_ref, tenant.id)["principal_uid"] == other.uid

    {verified, _, _} =
      verify_email_on_page(
        reauth_page,
        "pinned-owner@example.test",
        Map.merge(tenant_extra, %{reauth: reauth, returnTo: "/me"})
      )

    return_to = api_response(verified, 201)["returnTo"]
    assert URI.parse(return_to).path == "/me"

    entered =
      verified
      |> recycle()
      |> delete_req_header("accept")
      |> get(return_to)

    assert WebSession.pod_session(entered)["principal_uid"] == owner.uid
    assert BrowserSessions.identity(other_ref, tenant.id)["principal_uid"] == other.uid
  end

  defp verify_email_on_page(page, email, extra) do
    sent =
      api_post(
        browser_api_conn(page),
        "/api/v2/browser/sessions/email-otp/challenges",
        Map.put(extra, :email, email)
      )

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code(email)

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    {verified, challenge, code}
  end

  defp site_login(email) do
    {:ok, browser} = BrowserSessions.create()
    reference = BrowserSessions.reference(browser)

    {:ok, sent} =
      Domain.request_otp(reference, email, "story-#{browser.id}", scope: :site)

    code = delivered_code(email)

    {:ok, result} =
      Domain.verify_otp(reference, sent.challenge_id, code, "story-#{browser.id}")

    result
  end

  defp pod_login(conn, tenant, email) do
    conn =
      conn
      |> pod_conn(tenant)
      |> init_test_session(%{})
      |> get("/sessions/new")
      |> follow_login()
      |> browser_api_conn()

    payload = if @host_policy, do: %{tenantID: tenant.id, email: email}, else: %{email: email}

    sent = api_post(conn, "/api/v2/browser/sessions/email-otp/challenges", payload)

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code(email)

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    assert %{"returnTo" => target} = api_response(verified, 201)
    assert URI.parse(target).path == "/"
    assert URI.parse(target).host == tenant.slug <> ".ankole.localhost"
    reference = WebSession.authentication_reference(verified)

    page =
      verified
      |> recycle()
      |> pod_conn(tenant)
      |> put_req_header("accept", "text/html")
      |> get("/")

    {browser_api_conn(page), reference}
  end

  defp follow_login(%{status: 302} = conn), do: conn |> recycle() |> get(redirected_to(conn))
  defp follow_login(conn), do: conn

  defp browser_api_conn(page) do
    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, page.resp_body)
    origin = URI.to_string(%URI{scheme: to_string(page.scheme), host: page.host, port: page.port})

    page
    |> recycle()
    |> put_req_header("x-csrf-token", csrf)
    |> put_req_header("origin", origin)
    |> put_private(:plug_skip_csrf_protection, false)
  end

  defp delivered_code(email) do
    assert_receive {:smtp_message, _, [^email], message}, 5_000
    [_, code] = Regex.run(~r/code is (\d{6})/, SMTPFixture.text(message))
    code
  end

  defp update_policy(principal, policy) do
    {:ok, settings} = Ankole.Principals.PodAdministration.settings()

    Ankole.Principals.PodAdministration.update_settings(
      Ankole.AuthZ.Actor.new(principal),
      Map.put(settings, :loginPolicy, policy)
    )
  end
end
