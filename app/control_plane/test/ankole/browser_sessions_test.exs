defmodule Ankole.BrowserSessionsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, BrowserSessions, OIDC}
  alias Ankole.Principals.{SiteCredential, HumanAccess}

  defmodule SiteSource do
    @behaviour Ankole.IdentityProviders.SiteSources
    def authenticate(%{subject_id: _, auth_time: _} = proof), do: {:ok, proof}
    def authenticate(_), do: {:error, :invalid_authentication}
    def login_path, do: "/test/site-login"
    def display_name, do: "Test site source"
    def fresh_authentication?, do: true
  end

  setup do
    previous = Application.get_env(:ankole, :site_identity_sources, [])
    Application.put_env(:ankole, :site_identity_sources, [{"test-site", SiteSource}])
    on_exit(fn -> Application.put_env(:ankole, :site_identity_sources, previous) end)
    {:ok, browser} = BrowserSessions.create()
    {:ok, browser: BrowserSessions.reference(browser)}
  end

  test "OIDC state requires tenant_id and cannot reopen a consumed record",
       %{
         browser: browser
       } do
    oidc_state = oidc_flow(browser)

    assert {:error, error} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(BrowserSessions.OidcState, :begin_in_tx, %{
                 state: "missing-tenant",
                 browser_id: browser["id"],
                 provider_id: "local",
                 started_revision: 0,
                 redirect_uri: "https://op.test/callback",
                 expires_at: DateTime.add(DateTime.utc_now(), 60)
               })
             end)

    assert %{tenant_id: [_]} = errors_on(error)

    assert {:ok, consumed} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(oidc_state, :consume_in_tx, %{})
             end)

    assert consumed.consumed_at != nil

    assert {:error, _error} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(consumed, :consume_in_tx, %{})
             end)

    assert Repo.get!(BrowserSessions.OidcState, oidc_state.id).consumed_at == consumed.consumed_at
  end

  test "authentication scopes enforce their tenant invariants",
       %{
         browser: browser,
         tenant: tenant
       } do
    now = DateTime.utc_now()

    for scope <- [:site, :tenant], tenant_id <- [nil, tenant.id] do
      result =
        Repo.transact(fn ->
          Ankole.Ash.create(BrowserSessions.Authentication, :create_in_tx, %{
            browser_id: browser["id"],
            tenant_id: tenant_id,
            scope: scope,
            csrf_token: "scope-matrix",
            expires_at: DateTime.add(now, 60),
            provider_id: "test-site",
            subject_id: "scope-matrix-#{scope}-#{tenant_id || "site"}",
            revision: 1,
            challenge_started_at: now,
            amr: ["test"]
          })
        end)

      if scope == :site == is_nil(tenant_id) do
        assert {:ok, record} = result
        assert record.scope == scope
        assert record.tenant_id == tenant_id
      else
        assert {:error, error} = result

        assert Ankole.Ash.validation_details(error) == [
                 %{path: "tenant_id", message: "must match the authentication scope"}
               ]
      end
    end
  end

  test "logout revisions reject an advance past login without changing the browser", %{
    browser: browser
  } do
    row = Repo.get!(BrowserSessions.Session, browser["id"])

    assert {:error, error} =
             Repo.transact(fn ->
               Ankole.Ash.update(row, :logout_in_tx, %{revision: 2, logout_revision: 3})
             end)

    assert Ankole.Ash.validation_details(error) == [
             %{path: "logout_revision", message: "cannot exceed the browser revision"}
           ]

    assert_persisted_equal(Repo.get!(BrowserSessions.Session, row.id), row)

    for logout_revision <- [0, 1, 2] do
      assert {:ok, updated} =
               Repo.transact(fn ->
                 Ankole.Ash.update(row, :logout_in_tx, %{
                   revision: 2,
                   logout_revision: logout_revision
                 })
               end)

      assert updated.logout_revision == logout_revision
    end
  end

  test "a browser write owns its transaction; another transaction composes its _in_tx step", %{
    browser: browser
  } do
    attrs = %{
      state: "tx-boundary-state",
      provider_id: "local",
      redirect_uri: "https://op.test/callback"
    }

    assert_raise Ankole.Errors.Framework.NestedOperation, ~r/must run at the top level/, fn ->
      Repo.transact(fn -> BrowserSessions.begin_oidc_state(browser, attrs) end)
    end

    assert_raise Ankole.Errors.Framework.TransactionRequired, fn ->
      BrowserSessions.begin_oidc_state_in_tx(browser, attrs)
    end

    assert {:ok, created} =
             Repo.transact(fn ->
               BrowserSessions.begin_oidc_state_in_tx(browser, attrs)
             end)

    assert created.provider_id == "local"
  end

  test "OIDC identity selection binds the held proof without refreshing it and rejects another browser",
       %{
         browser: browser
       } do
    %{principal: human} = human_fixture()
    bind(human, "oidc-member")
    client_id = create_oidc_client!()

    {:ok, signed_in} = site_login(browser, "oidc-member")
    authentication = signed_in.authentication

    {:ok, request} =
      OIDC.AuthorizationRequests.begin(browser, client_id, %{"client_id" => client_id})

    assert {:ok, selected} =
             OIDC.AuthorizationRequests.select_identity(browser, request.id, ref(signed_in))

    assert selected.status == :authenticated
    assert selected.authentication_id == authentication.id
    assert selected.authentication_revision == authentication.revision

    Ankole.DataCase.assert_persisted_equal(
      Repo.get!(BrowserSessions.Authentication, authentication.id),
      authentication
    )

    {:ok, other_browser} = BrowserSessions.create()

    {:ok, other_req} =
      OIDC.AuthorizationRequests.begin(
        BrowserSessions.reference(other_browser),
        client_id,
        %{"client_id" => client_id}
      )

    assert {:error, :invalid_authentication} =
             OIDC.AuthorizationRequests.select_identity(
               BrowserSessions.reference(other_browser),
               other_req.id,
               ref(signed_in)
             )

    assert {:ok, _} = BrowserSessions.revoke(browser, ref(signed_in))

    {:ok, after_revoke_req} =
      OIDC.AuthorizationRequests.begin(browser, client_id, %{"client_id" => client_id})

    assert {:error, :browser_session_expired} =
             OIDC.AuthorizationRequests.select_identity(
               browser,
               after_revoke_req.id,
               ref(signed_in)
             )
  end

  test "the group reference grants no identity and a consumed OIDC state cannot be replayed",
       %{browser: browser, tenant: tenant} do
    %{principal: first} = human_fixture()
    first_flow = oidc_flow(browser)
    assert {:ok, completed} = complete_oidc(browser, first_flow.id, auth(first))

    assert nil == BrowserSessions.identity(browser, tenant.id)
    assert %{"principal_uid" => uid} = BrowserSessions.identity(ref(completed), tenant.id)
    assert uid == first.uid

    assert {:error, :login_expired} =
             complete_oidc(browser, first_flow.id, auth(first))
  end

  test "independent A and B callbacks both complete, while two callbacks for A cannot overwrite",
       %{browser: browser, tenant: tenant} do
    %{principal: a} = human_fixture()
    %{principal: b} = human_fixture()
    first_a = oidc_flow(browser)
    stale_a = oidc_flow(browser)
    flow_b = oidc_flow(browser)
    assert {:ok, b_login} = complete_oidc(browser, flow_b.id, auth(b))
    assert {:ok, a_login} = complete_oidc(browser, first_a.id, auth(a))
    assert {:error, :login_expired} = complete_oidc(browser, stale_a.id, auth(a))
    assert BrowserSessions.identity(ref(a_login), tenant.id)["principal_uid"] == a.uid
    assert BrowserSessions.identity(ref(b_login), tenant.id)["principal_uid"] == b.uid
    assert {:ok, _} = BrowserSessions.revoke(browser, ref(a_login))
    refute BrowserSessions.identity(ref(a_login), tenant.id)
    assert BrowserSessions.identity(ref(b_login), tenant.id)["principal_uid"] == b.uid
  end

  test "a revoked target stays fenced from its pending callback; a new login may sign in",
       %{browser: browser, tenant: tenant} do
    %{principal: human} = human_fixture()

    {:ok, signed_in} = BrowserSessions.authenticate(browser, auth(human))

    pending = oidc_flow(browser)
    {:ok, _} = BrowserSessions.revoke(browser, ref(signed_in))

    assert {:error, :login_expired} = complete_oidc(browser, pending.id, auth(human))

    assert {:ok, current} = BrowserSessions.authenticate(browser, auth(human))

    refute ref(current) == ref(signed_in)
    refute BrowserSessions.identity(ref(signed_in), tenant.id)
  end

  test "selection changes the default without mutating held authentication proofs", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: a} = human_fixture()
    %{principal: b} = human_fixture()

    {:ok, first} = BrowserSessions.authenticate(browser, auth(a))
    {:ok, second} = BrowserSessions.authenticate(browser, auth(b))

    assert BrowserSessions.current_reference(browser) == ref(second)
    assert {:ok, _} = BrowserSessions.activate(browser, ref(first), tenant.id)
    assert BrowserSessions.current_reference(browser) == ref(first)
    assert BrowserSessions.identity(ref(second), tenant.id)["principal_uid"] == b.uid
    other = Ankole.DataCase.create_tenant()

    assert {:error, :invalid_authentication} =
             BrowserSessions.activate(browser, ref(first), other.id)
  end

  test "additive authentications preserve independent tenant and OAuth proofs", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: first} = human_fixture()
    %{principal: second} = human_fixture()
    client_id = create_oidc_client!()

    {:ok, oauth_req} =
      OIDC.AuthorizationRequests.begin(browser, client_id, %{"client_id" => client_id})

    {:ok, oauth} =
      BrowserSessions.authenticate(browser, auth(first), oauth_request_id: oauth_req.id)

    {:ok, pod} = BrowserSessions.authenticate(browser, auth(second))

    assert BrowserSessions.identity(ref(oauth), tenant.id)["principal_uid"] == first.uid
    assert BrowserSessions.identity(ref(pod), tenant.id)["principal_uid"] == second.uid
  end

  test "global exit fences every old ceremony and authentication", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: human} = human_fixture()
    client_id = create_oidc_client!()

    {:ok, signed_in} = BrowserSessions.authenticate(browser, auth(human))

    {:ok, oauth_req} =
      OIDC.AuthorizationRequests.begin(browser, client_id, %{"client_id" => client_id})

    oidc_state = oidc_flow(browser, oauth_request_id: oauth_req.id)

    assert {:ok, _} = OIDC.AuthorizationRequests.get(browser, oauth_req.id)
    {:ok, _} = BrowserSessions.logout(browser)
    assert {:error, :login_expired} = OIDC.AuthorizationRequests.get(browser, oauth_req.id)

    assert {:error, :login_expired} = complete_oidc(browser, oidc_state.id, auth(human))

    refute BrowserSessions.identity(ref(signed_in), tenant.id)
    assert {:ok, _} = BrowserSessions.authenticate(browser, auth(human))
  end

  test "authorization consumes only its exact authentication proof once", %{browser: browser} do
    %{principal: human} = human_fixture()
    client_id = create_oidc_client!()

    request = %{
      "client_id" => client_id,
      "state" => "state",
      "nonce" => "nonce",
      "code_challenge" => "pkce"
    }

    {:ok, oauth_req} = OIDC.AuthorizationRequests.begin(browser, client_id, request)

    {:ok, completed} =
      BrowserSessions.authenticate(browser, auth(human), oauth_request_id: oauth_req.id)

    issue = fn params, authentication ->
      assert authentication["principal_uid"] == human.uid
      {:ok, params}
    end

    assert {:error, :login_expired} =
             OIDC.AuthorizationRequests.consume(browser, oauth_req.id, browser, issue)

    assert {:ok, ^request} =
             OIDC.AuthorizationRequests.consume(browser, oauth_req.id, ref(completed), issue)

    assert {:error, :login_expired} =
             OIDC.AuthorizationRequests.consume(browser, oauth_req.id, ref(completed), issue)
  end

  test "authentication beginning before Human revocation cannot finish after restoration", %{
    browser: browser
  } do
    %{principal: human} = human_fixture()
    oidc_state = oidc_flow(browser)
    restored = disable_and_restore(human)

    assert {:error, :human_access_revoked} =
             complete_oidc(browser, oidc_state.id, auth(restored))

    assert {:ok, _} = BrowserSessions.authenticate(browser, auth(restored))
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

    assert ref(initial) == ref(fresh)
    assert BrowserSessions.identity(ref(initial), second.id)["principal_uid"] == b.uid
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

    assert {:error, :invalid_authentication} =
             BrowserSessions.authenticate(
               browser,
               Map.put(auth(human), "provider_id", "test-site")
             )

    assert {:error, :identity_provider_not_allowed} =
             BrowserSessions.authenticate_site(browser, "unregistered", %{
               subject_id: "account",
               auth_time: 1
             })
  end

  test "provider callbacks require their exact browser, provider, and state", %{browser: browser} do
    {:ok, _} =
      BrowserSessions.begin_oidc_state(browser, %{
        state: "secret-state",
        provider_id: "lark",
        redirect_uri: "https://op.test/callback"
      })

    assert {:ok, _} = BrowserSessions.oidc_callback(browser, "lark", "secret-state")

    assert {:error, :login_expired} =
             BrowserSessions.oidc_callback(browser, "other", "secret-state")

    {:ok, other} = BrowserSessions.create()

    assert {:error, :login_expired} =
             BrowserSessions.oidc_callback(
               BrowserSessions.reference(other),
               "lark",
               "secret-state"
             )
  end

  test "new Pod access is atomic and does not rotate the site authentication", %{browser: browser} do
    {:ok, signed_in} = site_login(browser, "creator")
    reference = ref(signed_in)

    assert {:ok, created} =
             BrowserSessions.create_pod_access(reference, fn authentication ->
               # The callback runs in the BrowserSessions transaction.
               with {:ok, tenant} <-
                      Ankole.Tenants.create_in_tx(%{
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
               Ankole.Tenants.create_in_tx(%{
                 slug: "rollback-#{Ecto.UUID.generate()}",
                 display_name: "Roll back"
               })

               {:error, :creation_failed}
             end)

    refute Repo.exists?(from(t in Ankole.Tenants.Tenant, where: t.display_name == "Roll back"))
  end

  test "creating Pod access cannot reuse a restored Human's old evidence", %{
    browser: browser,
    tenant: tenant
  } do
    %{principal: human} = human_fixture()
    bind(human, "creator")
    {:ok, site} = site_login(browser, "creator")
    assert BrowserSessions.identity(ref(site), tenant.id)["principal_uid"] == human.uid
    restored = disable_and_restore(human)
    refute BrowserSessions.identity(ref(site), tenant.id)

    assert {:error, :invalid_authentication} =
             BrowserSessions.create_pod_access(ref(site), fn _ ->
               {:ok, %{principal: restored}}
             end)
  end

  test "both site and tenant authentications in the privileged Pod resolve site administrator identities",
       %{
         browser: browser,
         tenant: tenant
       } do
    :ok = set_privileged_tenant(tenant)
    %{principal: human} = human_fixture()
    bind(human, "operator")

    {:ok, site_completed} = site_login(browser, "operator")
    {:ok, tenant_completed} = BrowserSessions.authenticate(browser, auth(human))

    site_identity = BrowserSessions.identity(ref(site_completed), tenant.id)
    tenant_identity = BrowserSessions.identity(ref(tenant_completed), tenant.id)

    assert site_identity["principal_uid"] == human.uid
    assert site_identity["provider_scope"] == "site"
    assert tenant_identity["principal_uid"] == human.uid
    assert tenant_identity["provider_scope"] == "tenant"
    refute AuthZ.site_admin?(human.uid)

    {:ok, _} = first_site_admin_fixture(human.uid)
    assert AuthZ.site_admin?(human.uid)
    assert BrowserSessions.identity(ref(site_completed), tenant.id)["principal_uid"] == human.uid

    assert BrowserSessions.identity(ref(tenant_completed), tenant.id)["principal_uid"] ==
             human.uid
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

    client_id = create_oidc_client!()

    {:ok, session} = Ankole.OIDC.Sessions.ensure(client_id, auth, "openid offline_access")
    assert {:ok, _} = Ankole.OIDC.Sessions.validate(session.id, client_id, human.uid, "openid")
    Repo.delete_all(from(e in SiteCredential, where: e.principal_uid == ^human.uid))
    refute BrowserSessions.identity(ref(login), tenant.id)

    assert {:error, :authorization_revoked} =
             Ankole.OIDC.Sessions.validate(session.id, client_id, human.uid, "openid")

    assert {:error, :authorization_revoked} =
             Ankole.OIDC.Sessions.validate(
               session.id,
               client_id,
               human.uid,
               "openid offline_access",
               :code
             )

    assert {:ok, _} =
             Ankole.OIDC.Sessions.validate(
               session.id,
               client_id,
               human.uid,
               "openid offline_access"
             )
  end

  test "revoke_pod removes one Pod access and its RP sessions while keeping sibling Pods online until the last Pod exits",
       %{browser: browser, tenant: tenant_a} do
    tenant_b = Ankole.DataCase.create_tenant()
    %{principal: human_a} = human_fixture()
    bind(human_a, "shared@example.com")
    client_a = create_oidc_client!()

    {human_b, client_b} =
      Repo.with_tenant(tenant_b.id, fn ->
        %{principal: human} = human_fixture()
        bind(human, "shared@example.com")
        {human, create_oidc_client!()}
      end)

    {:ok, login} =
      BrowserSessions.authenticate_site(
        browser,
        "test-site",
        site_proof("shared@example.com"),
        scope: :site,
        target_tenant_id: tenant_a.id
      )

    auth_ref = ref(login)
    auth_a = BrowserSessions.identity(auth_ref, tenant_a.id)
    auth_b = BrowserSessions.identity(auth_ref, tenant_b.id)
    assert auth_a["principal_uid"] == human_a.uid
    assert auth_b["principal_uid"] == human_b.uid

    {:ok, session_a} = Ankole.OIDC.Sessions.ensure(client_a, auth_a, "openid")

    {:ok, session_b} =
      Repo.with_tenant(tenant_b.id, fn ->
        Ankole.OIDC.Sessions.ensure(client_b, auth_b, "openid")
      end)

    assert {:ok, %{browser: after_a, authentication_revoked?: false}} =
             BrowserSessions.revoke_pod(browser, auth_ref, tenant_a.id)

    assert is_nil(after_a.active_authentication_id)
    assert is_nil(after_a.active_tenant_id)
    refute BrowserSessions.identity(auth_ref, tenant_a.id)
    assert BrowserSessions.identity(auth_ref, tenant_b.id)["principal_uid"] == human_b.uid

    assert {:error, :authorization_revoked} =
             Ankole.OIDC.Sessions.validate(session_a.id, client_a, human_a.uid, "openid")

    assert {:ok, _} =
             Repo.with_tenant(tenant_b.id, fn ->
               Ankole.OIDC.Sessions.validate(session_b.id, client_b, human_b.uid, "openid")
             end)

    assert {:ok, %{authentication_revoked?: true}} =
             BrowserSessions.revoke_pod(browser, auth_ref, tenant_b.id)

    assert {:error, :browser_session_expired} = BrowserSessions.get_authentication(auth_ref)
    refute BrowserSessions.identity(auth_ref, tenant_b.id)

    assert {:error, :authorization_revoked} =
             Repo.with_tenant(tenant_b.id, fn ->
               Ankole.OIDC.Sessions.validate(session_b.id, client_b, human_b.uid, "openid")
             end)
  end

  defp oidc_flow(browser, opts \\ []) do
    {:ok, oidc_state} =
      BrowserSessions.begin_oidc_state(browser, %{
        state: "state-" <> Ecto.UUID.generate(),
        provider_id: Keyword.get(opts, :provider, "local"),
        oauth_request_id: Keyword.get(opts, :oauth_request_id),
        redirect_uri: "https://op.test/callback"
      })

    oidc_state
  end

  defp complete_oidc(browser, oidc_state_id, auth) do
    Repo.transact_top_level(fn ->
      BrowserSessions.consume_oidc_state_in_tx(browser, oidc_state_id, auth)
    end)
  end

  defp site_login(browser, subject) do
    BrowserSessions.authenticate_site(browser, "test-site", site_proof(subject), scope: :site)
  end

  defp create_oidc_client! do
    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Browser session fixture",
        enabled: true,
        type: "public",
        redirect_uris: ["https://client.example/callback"],
        scopes: ["openid", "offline_access"]
      })

    client.id
  end

  defp bind(principal, subject) do
    {:ok, identity} =
      Repo.transact(fn ->
        Ankole.Principals.bind_site_credential_in_tx(
          principal.uid,
          site_proof(subject) |> Map.put(:provider_id, "test-site")
        )
      end)

    identity
  end

  defp site_proof(subject),
    do: %{
      subject_id: subject,
      auth_time: System.system_time(:second),
      challenge_started_at: DateTime.utc_now(),
      amr: ["test"]
    }

  defp disable_and_restore(human) do
    {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    restore(human.uid)
  end

  defp restore(uid) do
    [restriction] = HumanAccess.restrictions(uid)
    {:ok, _} = HumanAccess.clear_restriction(uid, restriction.id, nil, "verified", "clear")
    {:ok, restored} = HumanAccess.restore(uid, nil, "verified", "restore")
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
