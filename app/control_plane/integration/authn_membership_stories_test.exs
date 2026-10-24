defmodule Ankole.Authn.MembershipStoriesTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  import Ankole.PrincipalsFixtures
  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Principals, Repo}
  alias Ankole.Authn.{Domain, SMTPFixture}
  alias Ankole.Principals.{HumanAccess, PodLoginPolicy}
  alias AnkoleWeb.Session, as: WebSession

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

    assert Repo.get!(Ankole.Principals.HumanUser, person.uid).email == "original@example.test"
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
    flow = URI.decode_query(URI.parse(path).query)["flow"]
    page = entry |> recycle() |> put_req_header("accept", "text/html") |> get(path)
    conn = browser_api_conn(page)
    providers = api_get(conn, "/api/v2/browser/identity-providers?flow=" <> flow)
    assert api_response(providers, 200)["identities"] == []

    sent =
      providers
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{
        flow: flow,
        email: "reauth@example.test"
      })

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code("reauth@example.test")

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: flow,
        challengeID: challenge,
        code: code
      })

    assert URI.parse(api_response(verified, 201)["returnTo"]).path == "/me"
    assert WebSession.pod_session(verified)["principal_uid"] == person.uid
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

    other_flow = URI.decode_query(URI.parse(redirected_to(entry)).query)["flow"]
    {other_conn, _, _} = verify_email_flow(entry, other_flow, "other-member@example.test")
    assert %{"returnTo" => _} = api_response(other_conn, 201)
    other_ref = WebSession.authentication_reference(other_conn)
    assert BrowserSessions.identity(other_ref, tenant.id)["principal_uid"] == other.uid

    pinned =
      other_conn
      |> recycle_api()
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(owner_ref))
      |> put_req_header("x-csrf-token", owner_csrf)
      |> api_post("/api/v2/pod/me/reauthentication", %{})

    path = api_response(pinned, 201)["loginURL"]
    flow = URI.decode_query(URI.parse(path).query)["flow"]
    assert {:ok, transaction} = WebSession.login_transaction(pinned, flow)
    assert transaction.expected_authentication_id == owner_ref["id"]
    assert transaction.request["reauthentication_principal_uid"] == owner.uid

    assert {:error, :reauthentication_required} =
             BrowserSessions.select_authorization(
               WebSession.browser_reference(pinned),
               flow,
               other_ref
             )

    {rejected, challenge, code} = verify_email_flow(pinned, flow, "other-member@example.test")
    assert api_error(rejected, 400)["code"] == "login_subject_mismatch"
    assert Repo.get!(Ankole.Authn.Challenge, challenge).verified_at

    repeated =
      rejected
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: flow,
        challengeID: challenge,
        code: code
      })

    assert api_error(repeated, 401)["code"] == "invalid_code"
    assert BrowserSessions.identity(owner_ref, tenant.id)["principal_uid"] == owner.uid
    assert BrowserSessions.identity(other_ref, tenant.id)["principal_uid"] == other.uid

    {verified, _, _} = verify_email_flow(repeated, flow, "pinned-owner@example.test")
    assert URI.parse(api_response(verified, 201)["returnTo"]).path == "/me"
    assert WebSession.pod_session(verified)["principal_uid"] == owner.uid
    assert BrowserSessions.identity(other_ref, tenant.id)["principal_uid"] == other.uid
  end

  defp verify_email_flow(conn, flow, email) do
    page =
      conn
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> get("/sessions/new?flow=" <> flow)

    sent =
      api_post(browser_api_conn(page), "/api/v2/browser/sessions/email-otp/challenges", %{
        flow: flow,
        email: email
      })

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code(email)

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: flow,
        challengeID: challenge,
        code: code
      })

    {verified, challenge, code}
  end

  defp site_login(email) do
    {:ok, browser} = BrowserSessions.create()
    reference = BrowserSessions.reference(browser)
    {:ok, flow} = BrowserSessions.begin_login(reference, :site, %{})
    {:ok, sent} = Domain.request_otp(reference, flow.id, email, "story-#{browser.id}")
    code = delivered_code(email)

    {:ok, result} =
      Domain.verify_otp(reference, flow.id, sent.challenge_id, code, "story-#{browser.id}")

    result
  end

  defp pod_login(conn, tenant, email) do
    conn = conn |> pod_conn(tenant) |> init_test_session(%{})
    {:ok, conn, flow} = WebSession.begin_login(conn, :pod, %{})

    conn = conn |> get("/sessions/new?flow=" <> flow.id) |> browser_api_conn()

    sent =
      api_post(conn, "/api/v2/browser/sessions/email-otp/challenges", %{
        flow: flow.id,
        email: email
      })

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code(email)

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: flow.id,
        challengeID: challenge,
        code: code
      })

    assert %{"returnTo" => target} = api_response(verified, 201)
    assert URI.parse(target).path == "/"
    assert URI.parse(target).host == tenant.slug <> ".ankole.localhost"
    reference = WebSession.authentication_reference(verified)
    page = verified |> recycle() |> put_req_header("accept", "text/html") |> get("/")
    {browser_api_conn(page), reference}
  end

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
