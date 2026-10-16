defmodule Ankole.BrowserSessionsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, BrowserSessions}
  alias Ankole.Principals.{ExternalIdentity, HumanAccess}

  defmodule SiteSource do
    @behaviour Ankole.IdentityProviders.SiteSources
    def authenticate(%{subject_id: _, auth_time: _} = proof), do: {:ok, proof}
    def authenticate(_), do: {:error, :invalid_authentication}
    def login_path, do: "/test/site-login"
    def display_name, do: "Test site source"
    def fresh_authentication?, do: true
  end

  setup do
    allow_cache_database_access()
    previous = Application.get_env(:ankole, :site_identity_sources, [])
    Application.put_env(:ankole, :site_identity_sources, [{"test-site", SiteSource}])
    on_exit(fn -> Application.put_env(:ankole, :site_identity_sources, previous) end)
    {:ok, browser} = BrowserSessions.create()
    {:ok, browser: BrowserSessions.reference(browser)}
  end

  test "default replacement cancels competing flows and the group reference grants no identity",
       %{browser: browser} do
    %{principal: first} = human_fixture()
    %{principal: second} = human_fixture()
    first_flow = flow(browser, :pod)
    second_flow = flow(browser, :pod)
    assert {:ok, completed} = BrowserSessions.complete_login(browser, first_flow.id, auth(first))

    assert {:error, :login_expired} =
             BrowserSessions.complete_login(browser, second_flow.id, auth(second))

    assert nil == BrowserSessions.authentication(browser, :pod)
    assert %{"principal_uid" => uid} = BrowserSessions.authentication(ref(completed), :pod)
    assert uid == first.uid

    assert {:error, :login_expired} =
             BrowserSessions.complete_login(browser, first_flow.id, auth(first))
  end

  test "independent A and B callbacks both complete, while two callbacks for A cannot overwrite",
       %{browser: browser} do
    %{principal: a} = human_fixture()
    %{principal: b} = human_fixture()
    first_a = flow(browser, :pod, %{}, mode: :add)
    stale_a = flow(browser, :pod, %{}, mode: :add)
    flow_b = flow(browser, :pod, %{}, mode: :add)
    assert {:ok, b_login} = BrowserSessions.complete_login(browser, flow_b.id, auth(b))
    assert {:ok, a_login} = BrowserSessions.complete_login(browser, first_a.id, auth(a))
    assert {:error, :login_expired} = BrowserSessions.complete_login(browser, stale_a.id, auth(a))
    assert BrowserSessions.authentication(ref(a_login), :pod)["principal_uid"] == a.uid
    assert BrowserSessions.authentication(ref(b_login), :pod)["principal_uid"] == b.uid
    assert {:ok, _} = BrowserSessions.revoke(browser, ref(a_login))
    refute BrowserSessions.authentication(ref(a_login), :pod)
    assert BrowserSessions.authentication(ref(b_login), :pod)["principal_uid"] == b.uid
  end

  test "a revoked target stays fenced from its pending callback; a new transaction may sign in",
       %{browser: browser} do
    %{principal: human} = human_fixture()

    {:ok, signed_in} =
      BrowserSessions.complete_login(browser, flow(browser, :pod).id, auth(human))

    pending = flow(browser, :pod, %{}, mode: :add)
    {:ok, _} = BrowserSessions.revoke(browser, ref(signed_in))

    assert {:error, :login_expired} =
             BrowserSessions.complete_login(browser, pending.id, auth(human))

    assert {:ok, current} =
             BrowserSessions.complete_login(browser, flow(browser, :pod).id, auth(human))

    refute ref(current) == ref(signed_in)
    refute BrowserSessions.authentication(ref(signed_in), :pod)
  end

  test "selection changes the default without mutating held authentication proofs", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: a} = human_fixture()
    %{principal: b} = human_fixture()

    {:ok, first} =
      BrowserSessions.complete_login(browser, flow(browser, :pod, %{}, mode: :add).id, auth(a))

    {:ok, second} =
      BrowserSessions.complete_login(browser, flow(browser, :pod, %{}, mode: :add).id, auth(b))

    assert BrowserSessions.current_reference(browser) == ref(second)
    assert {:ok, _} = BrowserSessions.activate(browser, ref(first), tenant.id)
    assert BrowserSessions.current_reference(browser) == ref(first)
    assert BrowserSessions.authentication(ref(second), :pod)["principal_uid"] == b.uid
    other = Ankole.DataCase.create_tenant()

    assert {:error, :invalid_authentication} =
             BrowserSessions.activate(browser, ref(first), other.id)
  end

  test "Console and OAuth replacement retain the original conflict rule", %{
    browser: browser,
    tenant: tenant
  } do
    :ok = set_privileged_tenant(tenant)
    %{principal: admin} = human_fixture()
    %{principal: human} = human_fixture()
    {:ok, _} = first_site_admin_fixture(admin.uid)
    {:ok, oauth} = BrowserSessions.complete_login(browser, flow(browser, :oauth).id, auth(human))

    {:ok, console} =
      BrowserSessions.complete_login(browser, flow(browser, :console).id, auth(admin))

    refute BrowserSessions.authentication(ref(oauth), :oauth)
    assert BrowserSessions.authentication(ref(console), :console)["principal_uid"] == admin.uid
    {:ok, _} = BrowserSessions.complete_login(browser, flow(browser, :oauth).id, auth(human))
    refute BrowserSessions.authentication(ref(console), :console)
  end

  test "global exit fences every old transaction and authentication", %{browser: browser} do
    %{principal: human} = human_fixture()

    {:ok, signed_in} =
      BrowserSessions.complete_login(browser, flow(browser, :pod).id, auth(human))

    transaction = flow(browser, :oauth, %{}, mode: :add)
    {:ok, _} = BrowserSessions.put_password_ticket(browser, transaction.id, auth(human))
    assert is_binary(BrowserSessions.transaction_csrf(browser, transaction.id))
    {:ok, _} = BrowserSessions.logout(browser)
    refute BrowserSessions.transaction_csrf(browser, transaction.id)

    assert {:error, :login_expired} =
             BrowserSessions.complete_login(browser, transaction.id, auth(human), fn ->
               flunk("a callback after global exit must not change the password")
             end)

    refute BrowserSessions.authentication(ref(signed_in), :pod)
    assert {:ok, _} = BrowserSessions.complete_login(browser, flow(browser, :pod).id, auth(human))
  end

  test "authorization consumes only its exact authentication proof once", %{browser: browser} do
    %{principal: human} = human_fixture()

    request = %{
      "client_id" => "client",
      "state" => "state",
      "nonce" => "nonce",
      "code_challenge" => "pkce"
    }

    transaction = flow(browser, :oauth, request)
    {:ok, completed} = BrowserSessions.complete_login(browser, transaction.id, auth(human))

    issue = fn params, authentication ->
      assert authentication["principal_uid"] == human.uid
      {:ok, params}
    end

    assert {:error, :login_expired} =
             BrowserSessions.consume_authorization(browser, transaction.id, browser, issue)

    assert {:ok, ^request} =
             BrowserSessions.consume_authorization(browser, transaction.id, ref(completed), issue)

    assert {:error, :login_expired} =
             BrowserSessions.consume_authorization(browser, transaction.id, ref(completed), issue)
  end

  test "authentication beginning before Human revocation cannot finish after restoration", %{
    browser: browser
  } do
    %{principal: human} = human_fixture()
    transaction = flow(browser, :pod)
    restored = disable_and_restore(human)

    assert {:error, :human_access_revoked} =
             BrowserSessions.complete_login(browser, transaction.id, auth(restored))

    assert {:ok, _} =
             BrowserSessions.complete_login(browser, flow(browser, :pod).id, auth(restored))
  end

  test "site authentication holds fixed per-Pod evidence; restoring a Human requires a real new login",
       %{browser: browser, tenant: tenant} do
    %{principal: a} = human_fixture()
    bind(a, "account")
    second = Ankole.DataCase.create_tenant()

    b =
      Repo.with_tenant(second.id, fn ->
        %{principal: b} = human_fixture()
        bind(b, "account")
        b
      end)

    {:ok, initial} = site_login(browser, "account")
    assert BrowserSessions.identity(ref(initial), tenant.id)["principal_uid"] == a.uid
    assert BrowserSessions.identity(ref(initial), second.id)["principal_uid"] == b.uid
    restored = disable_and_restore(a)
    refute BrowserSessions.identity(ref(initial), tenant.id)
    assert BrowserSessions.identity(ref(initial), second.id)["principal_uid"] == b.uid

    assert {:error, :invalid_authentication} =
             BrowserSessions.activate(browser, ref(initial), tenant.id)

    {:ok, fresh} = site_login(browser, "account")

    assert BrowserSessions.identity(ref(fresh), tenant.id)["access_version"] ==
             restored.access_version

    refute BrowserSessions.identity(ref(initial), second.id)
    assert BrowserSessions.identity(ref(fresh), second.id)["principal_uid"] == b.uid
  end

  test "site login during a Pod suspension cannot acquire evidence by later switching", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: human} = human_fixture()
    bind(human, "account")
    {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    {:ok, signed_in} = site_login(browser, "account")
    refute BrowserSessions.identity(ref(signed_in), tenant.id)
    restore(human.uid)
    refute BrowserSessions.identity(ref(signed_in), tenant.id)
    {:ok, new_login} = site_login(browser, "account")
    assert BrowserSessions.identity(ref(new_login), tenant.id)["principal_uid"] == human.uid
  end

  test "a tenant source cannot complete a reserved site source login", %{browser: browser} do
    %{principal: human} = human_fixture()
    transaction = flow(browser, :pod, %{}, provider: "test-site")

    assert {:error, :invalid_authentication} =
             BrowserSessions.complete_login(
               browser,
               transaction.id,
               Map.put(auth(human), "provider_id", "test-site")
             )

    assert {:error, :login_provider_mismatch} =
             BrowserSessions.complete_site_login(browser, transaction.id, "unregistered", %{
               subject_id: "account",
               auth_time: 1
             })
  end

  test "provider callbacks require their exact browser, provider, and state", %{browser: browser} do
    {:ok, transaction} = BrowserSessions.begin_login(browser, :pod, %{})

    {:ok, _} =
      BrowserSessions.bind_provider(
        browser,
        transaction.id,
        "lark",
        "secret-state",
        "https://op.test/callback"
      )

    assert {:ok, _} = BrowserSessions.callback(browser, "lark", "secret-state")
    assert {:error, :login_expired} = BrowserSessions.callback(browser, "other", "secret-state")
    {:ok, other} = BrowserSessions.create()

    assert {:error, :login_expired} =
             BrowserSessions.callback(BrowserSessions.reference(other), "lark", "secret-state")
  end

  test "new Pod access is atomic and does not rotate the site authentication", %{browser: browser} do
    {:ok, signed_in} = site_login(browser, "creator")
    reference = ref(signed_in)

    assert {:ok, created} =
             BrowserSessions.create_pod_access(reference, fn authentication ->
               with {:ok, tenant} <-
                      Ankole.Tenants.create(%{
                        slug: "pod-#{Ecto.UUID.generate()}",
                        display_name: "New Pod"
                      }) do
                 Repo.with_tenant(tenant.id, fn ->
                   %{principal: principal} = human_fixture()
                   bind(principal, authentication.subject_id)
                   {:ok, %{principal: principal, tenant: tenant}}
                 end)
               end
             end)

    assert BrowserSessions.identity(reference, created.tenant.id)["principal_uid"] ==
             created.principal.uid

    assert {:ok, current} = BrowserSessions.get_authentication(reference)
    assert current.auth_time == signed_in.authentication.auth_time
    assert current.expires_at == signed_in.authentication.expires_at

    assert {:error, :creation_failed} =
             BrowserSessions.create_pod_access(reference, fn _ ->
               Ankole.Tenants.create(%{
                 slug: "rollback-#{Ecto.UUID.generate()}",
                 display_name: "Roll back"
               })

               {:error, :creation_failed}
             end)

    refute Repo.exists?(from t in Ankole.Tenants.Tenant, where: t.display_name == "Roll back")
  end

  test "connecting an existing Pod requires its live proof and does not refresh old evidence", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: human} = human_fixture()
    {:ok, site} = site_login(browser, "connect")

    {:ok, native} =
      BrowserSessions.complete_login(
        browser,
        flow(browser, :pod, %{}, mode: :add).id,
        auth(human)
      )

    assert {:ok, uid} =
             BrowserSessions.connect_pod_access(
               ref(site),
               ref(native),
               tenant.id,
               fn authentication, principal ->
                 bind(principal, authentication.subject_id)
                 {:ok, principal.uid}
               end
             )

    assert uid == human.uid
    assert BrowserSessions.identity(ref(site), tenant.id)["principal_uid"] == uid
    restored = disable_and_restore(human)
    refute BrowserSessions.identity(ref(site), tenant.id)

    assert {:error, :invalid_authentication} =
             BrowserSessions.connect_pod_access(ref(site), ref(native), tenant.id, fn _, _ ->
               flunk("an old Pod proof cannot connect a restored Human")
             end)

    assert {:error, :invalid_authentication} =
             BrowserSessions.create_pod_access(ref(site), fn _ ->
               {:ok, %{principal: restored}}
             end)
  end

  test "a fixed transaction can be consumed once without minting a new authentication", %{
    browser: browser,
    tenant: tenant
  } do
    transaction = flow(browser, :pod, %{"target" => tenant.id})

    callback = fn transaction ->
      assert Repo.tenant_id!() == transaction.tenant_id
      {:ok, transaction.request}
    end

    assert {:ok, %{"target" => id}} =
             BrowserSessions.consume_login(browser, transaction.id, :pod, callback)

    assert id == tenant.id

    assert {:error, :login_expired} =
             BrowserSessions.consume_login(browser, transaction.id, :pod, callback)

    refute BrowserSessions.current_reference(browser)
  end

  test "site authentication uses the existing Console administrator boundary", %{
    browser: browser,
    tenant: tenant
  } do
    :ok = set_privileged_tenant(tenant)
    %{principal: human} = human_fixture()
    bind(human, "operator")
    transaction = flow(browser, :console, %{}, provider: "test-site")
    proof = %{subject_id: "operator", auth_time: System.system_time(:second)}

    assert {:error, :not_an_admin} =
             BrowserSessions.complete_site_login(browser, transaction.id, "test-site", proof)

    {:ok, _} = first_site_admin_fixture(human.uid)

    assert {:ok, completed} =
             BrowserSessions.complete_site_login(browser, transaction.id, "test-site", proof)

    assert BrowserSessions.authentication(ref(completed), :console)["principal_uid"] == human.uid
    {:ok, native} = BrowserSessions.complete_login(browser, flow(browser, :pod).id, auth(human))
    refute BrowserSessions.authentication(ref(native), :console)
  end

  test "removing a site binding invalidates online RP credentials and keeps explicit offline grants",
       %{
         browser: browser,
         tenant: tenant
       } do
    %{principal: human} = human_fixture()
    bind(human, "account")
    {:ok, login} = site_login(browser, "account")
    auth = BrowserSessions.identity(ref(login), tenant.id)

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Site identity fixture",
        enabled: true,
        type: "public",
        redirect_uris: ["https://client.example/callback"],
        scopes: ["openid", "offline_access"]
      })

    {:ok, session} = Ankole.OIDC.Sessions.ensure(client.id, auth, "openid offline_access")
    assert {:ok, _} = Ankole.OIDC.Sessions.validate(session.id, client.id, human.uid, "openid")
    Repo.delete_all(from e in ExternalIdentity, where: e.principal_uid == ^human.uid)
    refute BrowserSessions.identity(ref(login), tenant.id)

    assert {:error, :authorization_revoked} =
             Ankole.OIDC.Sessions.validate(session.id, client.id, human.uid, "openid")

    assert {:error, :authorization_revoked} =
             Ankole.OIDC.Sessions.validate(
               session.id,
               client.id,
               human.uid,
               "openid offline_access",
               :code
             )

    assert {:ok, _} =
             Ankole.OIDC.Sessions.validate(
               session.id,
               client.id,
               human.uid,
               "openid offline_access"
             )
  end

  defp flow(browser, purpose, request \\ %{}, opts \\ []) do
    {:ok, transaction} =
      BrowserSessions.begin_login(browser, purpose, request, Keyword.delete(opts, :provider))

    {:ok, transaction} =
      BrowserSessions.bind_provider(
        browser,
        transaction.id,
        Keyword.get(opts, :provider, "local")
      )

    transaction
  end

  defp site_login(browser, subject) do
    transaction = flow(browser, :site, %{}, mode: :add, provider: "test-site")

    BrowserSessions.complete_site_login(browser, transaction.id, "test-site", %{
      subject_id: subject,
      auth_time: System.system_time(:second)
    })
  end

  defp bind(principal, subject) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(%{
      principal_uid: principal.uid,
      provider: "test-site",
      external_id: subject
    })
    |> Repo.insert!()
  end

  defp disable_and_restore(human) do
    {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    restore(human.uid)
  end

  defp restore(uid) do
    [restriction] = HumanAccess.restrictions(uid)
    {:ok, _} = HumanAccess.clear_restriction(uid, restriction.id, nil, "verified", "clear")
    {:ok, review} = AuthZ.restoration_review(uid)
    {:ok, restored} = HumanAccess.restore(uid, review.fingerprint, nil, "verified", "restore")
    restored
  end

  defp ref(result), do: BrowserSessions.reference(result.authentication)

  defp auth(principal),
    do: %{
      "principal_uid" => principal.uid,
      "access_version" => principal.access_version,
      "provider_id" => "local",
      "external_id" => principal.uid,
      "auth_time" => System.system_time(:second)
    }
end
