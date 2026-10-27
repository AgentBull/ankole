defmodule Ankole.Authn.LarkCredentialBindingTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  import Ankole.PrincipalsFixtures

  alias Ankole.Authn.SMTPFixture
  alias Ankole.{AppConfigure, BrowserSessions, IdentityProviders, Principals, Repo}
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias AnkoleWeb.Session, as: WebSession

  defmodule LarkPeer do
    @moduledoc false
    import Plug.Conn

    def init(parent), do: parent

    def call(conn, parent) do
      body =
        case conn.request_path do
          "/open-apis/auth/v3/tenant_access_token/internal" ->
            %{code: 0, tenant_access_token: "tenant-token", expire: 7200}

          "/open-apis/authen/v1/oidc/access_token" ->
            {:ok, body, _conn} = read_body(conn)
            code = Ankole.JSON.decode!(body)["code"]
            send(parent, :lark_code_exchanged)
            %{code: 0, data: %{access_token: code, expires_in: 7200}}

          "/open-apis/authen/v1/user_info" ->
            if get_req_header(conn, "authorization") == ["Bearer other-code"],
              do: %{code: 0, data: other_user()},
              else: %{code: 0, data: user()}

          "/open-apis/contact/v3/users/carol" ->
            %{code: 0, data: %{user: user()}}

          "/open-apis/contact/v3/users/other" ->
            %{code: 0, data: %{user: other_user()}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Ankole.JSON.encode!(body))
    end

    defp user,
      do: %{user_id: "carol", name: "Carol", email: "carol@corp.test"}

    defp other_user,
      do: %{user_id: "other", name: "Other", email: "other@corp.test"}
  end

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    {:ok, _} = AppConfigure.put_global_by_key("setup.completed", true)

    server =
      start_supervised!(
        {Bandit, plug: {LarkPeer, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    previous = Application.get_env(:ankole, LarkConfig)

    Application.put_env(:ankole, LarkConfig, client_opts: [base_url: "http://127.0.0.1:#{port}"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, LarkConfig, previous),
        else: Application.delete_env(:ankole, LarkConfig)
    end)

    {:ok, _} =
      IdentityProviders.save_provider(
        "lark-main",
        "lark",
        %{
          "appID" => "cli_credential_binding",
          "appSecret" => "test-secret",
          "sync" => %{"contacts" => false}
        },
        true
      )

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

  test "Lark members bind email after a recent ceremony and can repeat stale authentication", %{
    conn: conn,
    tenant: tenant
  } do
    entry =
      conn
      |> pod_conn(tenant)
      |> put_req_header("accept", "text/html")
      |> get("/sessions/new?return_to=/me")

    signed_in = complete_lark(entry, %{"return_to" => "/me"})
    assert_receive :lark_code_exchanged
    assert redirected_to(signed_in) == "/me"
    authentication = WebSession.pod_session(signed_in)
    uid = authentication["principal_uid"]
    assert authentication["auth_time"] == nil

    page = signed_in |> recycle() |> put_req_header("accept", "text/html") |> get("/me")

    sent =
      api_post(browser_api_conn(page), "/api/v2/pod/me/email/challenges", %{
        email: "carol@personal.test"
      })

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code("carol@personal.test")

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/pod/me/email/verifications", %{challengeID: challenge, code: code})

    assert %{"ok" => true, "authenticationRef" => encoded_reference, "csrfToken" => csrf} =
             api_response(verified, 201)

    assert [%{identifier: "carol@personal.test"}] = Principals.principal_site_credentials(uid)
    reference = WebSession.authentication_reference(verified)
    {:ok, proof} = BrowserSessions.get_authentication(reference)
    assert proof.provider_id == "email_otp"
    assert proof.subject_id == "carol@personal.test"
    assert WebSession.pod_session(verified)["principal_uid"] == uid

    Repo.update!(
      Ecto.Changeset.change(proof, authenticated_at: DateTime.add(DateTime.utc_now(), -901))
    )

    refused =
      verified
      |> recycle_api()
      |> put_req_header("x-ankole-authentication", encoded_reference)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/pod/me/email/challenges", %{email: "next@personal.test"})

    assert api_error(refused, 403)["code"] == "reauthentication_required"

    entry =
      refused
      |> recycle_api()
      |> api_post("/api/v2/pod/me/reauthentication", %{})

    path = api_response(entry, 201)["loginURL"]
    reauth = URI.decode_query(URI.parse(path).query)["reauth"]
    page = entry |> recycle() |> put_req_header("accept", "text/html") |> get(path)

    choices =
      api_get(browser_api_conn(page), "/api/v2/browser/identity-providers", %{"reauth" => reauth})

    assert api_response(choices, 200)["identities"] == []

    renewed = complete_lark(entry, %{"reauth" => reauth, "return_to" => "/me"})
    assert_receive :lark_code_exchanged
    assert redirected_to(renewed) == "/me"
    assert WebSession.pod_session(renewed)["principal_uid"] == uid
    assert WebSession.pod_session(renewed)["auth_time"] == nil

    page = renewed |> recycle() |> put_req_header("accept", "text/html") |> get("/me")

    sent =
      api_post(browser_api_conn(page), "/api/v2/pod/me/email/challenges", %{
        email: "next@personal.test"
      })

    assert is_binary(api_response(sent, 201)["challengeID"])
    assert is_binary(delivered_code("next@personal.test"))

    assert {:error, :authentication_time_unavailable} =
             Ankole.OIDC.LoginPolicy.completed_authentication_allowed?(
               WebSession.pod_session(renewed),
               %{"prompt" => ["login"]}
             )
  end

  test "reauthentication rolls back admission when the enterprise returns another Human", %{
    conn: conn,
    tenant: tenant
  } do
    owner = human_fixture(%{email: "owner@example.test"}).principal
    signed_in = email_login(conn, tenant, "owner@example.test")
    reference = WebSession.authentication_reference(signed_in)
    page = signed_in |> recycle() |> put_req_header("accept", "text/html") |> get("/me")
    entry = api_post(browser_api_conn(page), "/api/v2/pod/me/reauthentication", %{})
    path = api_response(entry, 201)["loginURL"]
    reauth = URI.decode_query(URI.parse(path).query)["reauth"]

    rejected = complete_lark(entry, %{"reauth" => reauth, "return_to" => "/me"}, "other-code")
    assert json_response(rejected, 400)["error"] == "login_subject_mismatch"
    assert_receive :lark_code_exchanged
    assert [] == Principals.list_external_identities!(query: [filter: [provider: "lark-main"]])
    assert [principal] = Principals.list_principals!(query: [filter: [type: :human]])
    assert principal.uid == owner.uid
    assert BrowserSessions.identity(reference, tenant.id)["principal_uid"] == owner.uid
  end

  test "a pending Guest invitation keeps its role through Lark and preserves another Pod identity",
       %{
         conn: conn,
         tenant: target
       } do
    admin = human_fixture(%{email: "admin@corp.test"}).principal

    {:ok, _} =
      create_external_identity(%{
        principal_uid: admin.uid,
        provider: "lark-main",
        external_id: "administrator"
      })

    {:ok, policy} = Ankole.Principals.PodLoginPolicy.get()

    {:ok, _} =
      update_policy(admin, Map.put(policy, "allow_email_otp", false))

    {:ok, created} =
      Principals.create_invitation(admin.uid, %{
        kind: :email,
        invited_email: "carol@corp.test",
        membership: :guest,
        expires_at: DateTime.add(DateTime.utc_now(), 3600),
        max_uses: 1
      })

    original = Ankole.DataCase.create_tenant()

    original_member =
      Repo.with_tenant(original.id, fn ->
        :ok = Ankole.Tenants.ensure_scaffold(original)
        human_fixture(%{email: "carol@corp.test"}).principal
      end)

    signed_in = email_login(conn, original, "carol@corp.test")
    reference = WebSession.authentication_reference(signed_in)
    page = signed_in |> recycle() |> put_req_header("accept", "text/html") |> get("/")
    session = api_get(browser_api_conn(page), "/api/v2/browser/session")

    assert [%{"requiresSSO" => true, "invitationID" => invitation_id}] =
             api_response(session, 200)["pendingAccounts"]

    assert invitation_id == created.invitation.id

    activated =
      session
      |> recycle_api()
      |> api_post("/api/v2/browser/authentications/current", %{
        authenticationRef: BrowserSessions.encode_reference(reference),
        tenantID: target.id
      })

    target_url = URI.parse(api_response(activated, 201)["podURL"])
    assert target_url.host == URI.parse(AnkoleWeb.PodURL.origin(activated, target)).host
    invitation = URI.decode_query(target_url.query)["invitation"]

    target_page =
      activated
      |> recycle()
      |> pod_conn(target)
      |> put_req_header("accept", "text/html")
      |> get(target_url.path <> "?" <> target_url.query)

    joined = complete_lark(target_page, %{"invitation" => invitation})
    assert_receive :lark_code_exchanged
    assert redirected_to(joined) == "/"
    uid = WebSession.pod_session(joined)["principal_uid"]
    assert {:ok, %{membership: :guest}} = Principals.get_principal(uid)
    assert Repo.get!(Ankole.Principals.Invitation, invitation_id).used_count == 1

    assert BrowserSessions.identity(reference, original.id)["principal_uid"] ==
             original_member.uid

    page = joined |> recycle() |> put_req_header("accept", "text/html") |> get("/")
    session = api_get(browser_api_conn(page), "/api/v2/browser/session")
    accounts = api_response(session, 200)["accounts"]
    assert Enum.any?(accounts, &(&1["principalUID"] == uid and &1["tenant"]["id"] == target.id))

    assert Enum.any?(accounts, fn account ->
             account["principalUID"] == original_member.uid and
               account["tenant"]["id"] == original.id
           end)
  end

  defp complete_lark(entry, params, code \\ "carol-code") do
    authorization =
      entry
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> get("/sessions/oidc/lark-main/authorization", params)

    state = URI.decode_query(URI.parse(redirected_to(authorization)).query)["state"]

    authorization
    |> recycle()
    |> put_req_header("accept", "text/html")
    |> get("/sessions/oidc/lark-main/callback", %{"state" => state, "code" => code})
  end

  defp email_login(conn, tenant, email) do
    page =
      conn |> pod_conn(tenant) |> put_req_header("accept", "text/html") |> get("/sessions/new")

    sent =
      api_post(browser_api_conn(page), "/api/v2/browser/sessions/email-otp/challenges", %{
        email: email
      })

    challenge = api_response(sent, 201)["challengeID"]
    code = delivered_code(email)

    verified =
      sent
      |> recycle_api()
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    assert %{"returnTo" => _} = api_response(verified, 201)
    verified
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
