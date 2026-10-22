defmodule Ankole.OIDC.CleanupExpiredCredentialsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.OIDC
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.Jobs.CleanupExpiredCredentials
  alias Ankole.OIDC.RefreshToken
  alias Ankole.Repo

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "the cleanup job deletes expired codes and refresh tokens" do
    human = human_fixture()
    client_id = create_client!()
    now = DateTime.utc_now(:microsecond)

    expired_code = insert_code!(client_id, human.principal.uid, "expired-code", before(now))
    active_code = insert_code!(client_id, human.principal.uid, "active-code", after_now(now))

    expired_refresh =
      insert_refresh!(client_id, human.principal.uid, "expired-refresh", before(now))

    active_refresh =
      insert_refresh!(client_id, human.principal.uid, "active-refresh", after_now(now))

    assert :ok =
             CleanupExpiredCredentials.perform(%Oban.Job{
               id: System.unique_integer([:positive]),
               queue: "default",
               attempt: 1
             })

    refute Repo.get(AuthorizationCode, expired_code.digest)
    assert Repo.get(AuthorizationCode, active_code.digest)
    refute Repo.get(RefreshToken, expired_refresh.digest)
    assert Repo.get(RefreshToken, active_refresh.digest)
  end

  test "cleanup removes expired session state but retains recent hints, credentials, and failed delivery" do
    alias Ankole.BrowserSessions
    alias Ankole.OIDC.LogoutDelivery
    alias Ankole.OIDC.LogoutRequest
    alias Ankole.OIDC.Session
    human = human_fixture()
    client_id = create_client!()
    now = DateTime.utc_now(:microsecond)
    old = DateTime.add(now, -2 * 24 * 60 * 60)

    make_session = fn attrs ->
      {:ok, session} = Ankole.OIDCFixtures.session(human.principal.uid, client_id, "openid")

      Repo.get!(BrowserSessions.Session, session.browser_id)
      |> Ecto.Changeset.change(expires_at: old)
      |> Repo.update!()

      session |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end

    expired = make_session.(expires_at: old, ended_at: old)
    recent = make_session.(expires_at: old, ended_at: DateTime.add(now, -60))
    offline = make_session.(expires_at: DateTime.add(now, 3600), ended_at: old)
    credential = make_session.(expires_at: old, ended_at: old)

    insert_refresh_for_session!(credential, "protected-refresh", DateTime.add(now, 3600))

    deliveries =
      for status <- [:pending, :delivering, :failed, :delivered] do
        session = make_session.(expires_at: old, ended_at: old)

        {:ok, delivery} =
          Repo.transact(fn _repo ->
            with {:ok, delivery} <-
                   Ankole.Ash.create(LogoutDelivery, :enqueue_in_tx, %{
                     session_id: session.id,
                     endpoint: "https://rp.example/logout",
                     deadline: old
                   }) do
              case status do
                :pending -> {:ok, delivery}
                :delivering -> Ankole.Ash.update(delivery, :claim_in_tx, %{at: old})
                :failed -> Ankole.Ash.update(delivery, :exhaust_in_tx, %{})
                :delivered -> Ankole.Ash.update(delivery, :acknowledge_in_tx, %{at: old})
              end
            end
          end)

        {session, delivery}
      end

    {:ok, anonymous} = BrowserSessions.create()

    {:ok, login} =
      BrowserSessions.begin_login(BrowserSessions.reference(anonymous), :console, %{})

    login |> Ecto.Changeset.change(expires_at: old) |> Repo.update!()

    {:ok, request} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(LogoutRequest, :prepare_in_tx, %{
          browser_id: anonymous.id,
          browser_revision: anonymous.revision,
          expires_at: old
        })
      end)

    anonymous |> Ecto.Changeset.change(expires_at: old) |> Repo.update!()

    {:ok, active_browser} = BrowserSessions.create()

    {:ok, active_login} =
      BrowserSessions.begin_login(BrowserSessions.reference(active_browser), :console, %{})

    {:ok, expired_login} =
      BrowserSessions.begin_login(BrowserSessions.reference(active_browser), :console, %{})

    expired_login |> Ecto.Changeset.change(expires_at: old) |> Repo.update!()

    counts = OIDC.cleanup_expired_credentials(now)
    assert counts.oidc_sessions == 2
    refute Map.has_key?(counts, :browser_sessions)
    assert Repo.get(BrowserSessions.Session, expired.browser_id)
    assert Repo.get(BrowserSessions.Session, anonymous.id)

    assert :ok = CleanupExpiredCredentials.perform(%Oban.Job{})

    refute Repo.get(Session, expired.id)
    refute Repo.get(BrowserSessions.Session, expired.browser_id)
    refute Repo.get(BrowserSessions.Session, anonymous.id)
    refute Repo.get(BrowserSessions.LoginTransaction, login.id)
    refute Repo.get(LogoutRequest, request.id)
    refute Repo.get(BrowserSessions.LoginTransaction, expired_login.id)
    assert Repo.get(BrowserSessions.Session, active_browser.id)
    assert Repo.get(BrowserSessions.LoginTransaction, active_login.id)

    for session <- [recent, offline, credential] do
      assert Repo.get(Session, session.id)
      assert Repo.get(BrowserSessions.Session, session.browser_id)
    end

    for {session, delivery} <- deliveries do
      if delivery.status == :delivered do
        refute Repo.get(Session, session.id)
        refute Repo.get(LogoutDelivery, delivery.id)
        refute Repo.get(BrowserSessions.Session, session.browser_id)
      else
        assert Repo.get(Session, session.id)
        assert Repo.get(LogoutDelivery, delivery.id)
        assert Repo.get(BrowserSessions.Session, session.browser_id)
      end
    end

    assert Repo.get(RefreshToken, "protected-refresh")
    assert OIDC.cleanup_expired_credentials(now).oidc_sessions == 0
  end

  test "site cleanup runs once after every tenant and preserves a shared browser's remaining RP",
       %{
         tenant: original
       } do
    alias Ankole.BrowserSessions
    alias Ankole.OIDC.Session

    {:ok, browser} = BrowserSessions.create()
    old = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60)
    suspended = create_tenant()
    deleting = create_tenant()

    sessions =
      for tenant <- [original, suspended, deleting] do
        Repo.with_tenant(tenant.id, fn ->
          human = human_fixture()
          client_id = create_client!()

          {:ok, session} =
            Ankole.OIDCFixtures.session(human.principal.uid, client_id, "openid",
              browser: browser
            )

          Repo.update!(
            Ecto.Changeset.change(session,
              expires_at: old,
              ended_at: if(tenant.id == deleting.id, do: DateTime.utc_now(), else: old)
            )
          )
        end)
      end

    Repo.update!(Ecto.Changeset.change(browser, expires_at: old))
    Repo.update!(Ecto.Changeset.change(suspended, suspended_at: DateTime.utc_now()))
    Repo.update!(Ecto.Changeset.change(deleting, deleting_at: DateTime.utc_now()))
    tenant_count = length(Ankole.Tenants.list())
    handler = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        &__MODULE__.capture_cleanup/4,
        self()
      )

    try do
      assert :ok = CleanupExpiredCredentials.perform(%Oban.Job{})
      assert_receive {:browser_cleanup, cutoff}
      refute_receive {:browser_cleanup, _}

      for _ <- 1..tenant_count do
        assert_receive {:credential_cleanup, ^cutoff}
      end

      for session <- sessions do
        Repo.with_tenant(session.tenant_id, fn ->
          if session.tenant_id == deleting.id do
            assert Repo.get(Session, session.id)
          else
            refute Repo.get(Session, session.id)
          end
        end)
      end

      assert Repo.get(BrowserSessions.Session, browser.id)
      assert Repo.tenant_id!() == original.id
    after
      :telemetry.detach(handler)
    end
  end

  def capture_cleanup(_event, _measurements, %{query: query, params: params}, owner) do
    if self() == owner do
      cond do
        String.starts_with?(query, ~s(DELETE FROM "browser_sessions")) ->
          send(owner, {:browser_cleanup, hd(params)})

        String.starts_with?(query, ~s(DELETE FROM "oidc_authorization_codes")) ->
          send(owner, {:credential_cleanup, hd(params)})

        true ->
          :ok
      end
    end
  end

  defp create_client! do
    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Cleanup Client",
        enabled: true,
        type: "public",
        redirect_uris: ["https://cleanup.example.test/callback"],
        scopes: ["openid"],
        allowed_group_ids: [],
        allowed_models: %{}
      })

    client.id
  end

  defp insert_code!(client_id, principal_uid, digest, expires_at) do
    {:ok, session} = Ankole.OIDCFixtures.session(principal_uid, client_id, "openid")

    {:ok, code} =
      Repo.transact(fn ->
        Ankole.Ash.create(AuthorizationCode, :issue_in_tx, %{
          digest: digest,
          session_id: session.id,
          client_id: client_id,
          principal_uid: principal_uid,
          redirect_uri: "https://cleanup.example.test/callback",
          scope: "openid",
          code_challenge: String.duplicate("a", 43),
          expires_at: expires_at
        })
      end)

    code
  end

  defp insert_refresh!(client_id, principal_uid, digest, absolute_expires_at) do
    {:ok, session} =
      Ankole.OIDCFixtures.session(principal_uid, client_id, "openid offline_access")

    insert_refresh_for_session!(session, digest, absolute_expires_at)
  end

  defp insert_refresh_for_session!(session, digest, expiry) do
    deadline = DateTime.to_unix(expiry)

    # The code exchange inserts the first token of a family in its transaction.
    assert {:ok, :ok} =
             Repo.transact(fn ->
               {:ok,
                Ankole.OIDC.RefreshStore.insert(%{
                  token_hash: digest,
                  family_id: digest,
                  generation: 0,
                  data: %{
                    subject: session.principal_uid,
                    client_id: session.client_id,
                    scope: ["openid", "offline_access"],
                    resource: [],
                    dpop_jkt: nil,
                    acr: nil,
                    auth_time: nil,
                    family_expires_at: deadline,
                    claims: %{"session_id" => session.id}
                  },
                  expires_at: deadline,
                  consumed: false,
                  consumed_at: nil,
                  successor: nil
                })}
             end)

    Repo.get!(RefreshToken, digest)
  end

  defp before(now), do: DateTime.add(now, -1, :second)
  defp after_now(now), do: DateTime.add(now, 60, :second)
end
