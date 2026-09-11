defmodule Ankole.OIDC.CleanupExpiredCredentialsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.OIDC
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.Jobs.CleanupExpiredCredentials
  alias Ankole.OIDC.RefreshToken
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
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
    alias Ankole.OIDC.{LogoutDelivery, LogoutRequest, Session}
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

    %RefreshToken{}
    |> RefreshToken.changeset(%{
      digest: "protected-refresh",
      session_id: credential.id,
      client_id: client_id,
      principal_uid: human.principal.uid,
      scope: "openid offline_access",
      issued_at: old,
      absolute_expires_at: DateTime.add(now, 3600)
    })
    |> Repo.insert!()

    deliveries =
      for status <- [:pending, :delivering, :failed, :delivered] do
        session = make_session.(expires_at: old, ended_at: old)

        delivery =
          %LogoutDelivery{}
          |> Ecto.Changeset.change(
            session_id: session.id,
            endpoint: "https://rp.example/logout",
            status: status,
            deadline: old
          )
          |> Repo.insert!()

        {session, delivery}
      end

    {:ok, anonymous} = BrowserSessions.create()

    {:ok, login} =
      BrowserSessions.begin_login(BrowserSessions.reference(anonymous), :console, %{})

    login |> Ecto.Changeset.change(expires_at: old) |> Repo.update!()

    request =
      %LogoutRequest{}
      |> Ecto.Changeset.change(
        browser_id: anonymous.id,
        browser_generation: anonymous.generation,
        expires_at: old
      )
      |> Repo.insert!()

    anonymous |> Ecto.Changeset.change(expires_at: old) |> Repo.update!()

    {:ok, active_browser} = BrowserSessions.create()

    {:ok, active_login} =
      BrowserSessions.begin_login(BrowserSessions.reference(active_browser), :console, %{})

    {:ok, expired_login} =
      BrowserSessions.begin_login(BrowserSessions.reference(active_browser), :console, %{})

    expired_login |> Ecto.Changeset.change(expires_at: old) |> Repo.update!()

    counts = OIDC.cleanup_expired_credentials(now)
    assert counts.browser_sessions == 3
    assert counts.oidc_sessions == 2
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
      else
        assert Repo.get(Session, session.id)
        assert Repo.get(LogoutDelivery, delivery.id)
      end
    end

    assert Repo.get(RefreshToken, "protected-refresh")
    assert OIDC.cleanup_expired_credentials(now).oidc_sessions == 0
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

    %AuthorizationCode{}
    |> AuthorizationCode.changeset(%{
      digest: digest,
      session_id: session.id,
      client_id: client_id,
      principal_uid: principal_uid,
      redirect_uri: "https://cleanup.example.test/callback",
      scope: "openid",
      code_challenge_digest: "challenge",
      code_challenge_method: "S256",
      expires_at: expires_at
    })
    |> Repo.insert!()
  end

  defp insert_refresh!(client_id, principal_uid, digest, absolute_expires_at) do
    {:ok, session} =
      Ankole.OIDCFixtures.session(principal_uid, client_id, "openid offline_access")

    %RefreshToken{}
    |> RefreshToken.changeset(%{
      digest: digest,
      session_id: session.id,
      client_id: client_id,
      principal_uid: principal_uid,
      scope: "openid offline_access",
      issued_at: DateTime.add(absolute_expires_at, -60, :second),
      absolute_expires_at: absolute_expires_at
    })
    |> Repo.insert!()
  end

  defp before(now), do: DateTime.add(now, -1, :second)
  defp after_now(now), do: DateTime.add(now, 60, :second)
end
