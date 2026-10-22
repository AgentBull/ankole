defmodule Ankole.OIDC.SessionResourceActionsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.OIDC.{Logout, LogoutDelivery, LogoutRequest, Session, Sessions}

  setup do
    %{principal: human} = human_fixture()

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Session actions",
        type: "public",
        enabled: true,
        allowed_models: %{},
        allowed_group_ids: [],
        redirect_uris: ["https://rp.example/callback"],
        scopes: ["openid"]
      })

    {:ok, session} = Ankole.OIDCFixtures.session(human.uid, client.id, "openid")
    %{session: session}
  end

  test "Session extension preserves identity and never reduces its deadline", %{session: session} do
    assert {:ok, shorter} =
             Repo.transact(fn ->
               Ankole.Ash.update(session, :extend_in_tx, %{
                 expires_at: DateTime.add(session.expires_at, -60)
               })
             end)

    assert shorter.expires_at == session.expires_at
    deadline = DateTime.add(session.expires_at, 3600)

    assert {:ok, extended} =
             Repo.transact(fn ->
               Ankole.Ash.update(shorter, :extend_in_tx, %{expires_at: deadline})
             end)

    assert extended.expires_at == deadline

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(extended, :extend_in_tx, %{
                 expires_at: deadline,
                 client_id: Ankole.Ecto.UUIDv7.autogenerate(),
                 principal_uid: "replaced-person",
                 authentication_revision: session.authentication_revision + 1,
                 access_version: session.access_version + 1
               })
             end)

    assert MapSet.new(Enum.map(rejected.errors, & &1.input)) ==
             MapSet.new([:client_id, :principal_uid, :authentication_revision, :access_version])

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Session, session.id), extended)
  end

  test "repeated revocation and logout retain their first markers", %{session: session} do
    first = DateTime.utc_now()
    second = DateTime.add(first, 60)

    assert {:ok, revoked} =
             Repo.transact(fn -> Ankole.Ash.update(session, :revoke_in_tx, %{at: first}) end)

    assert {:ok, repeated} = Sessions.revoke(session.id)
    assert repeated.revoked_at == revoked.revoked_at

    assert {:ok, ended} =
             Repo.transact(fn ->
               Ankole.Ash.update(repeated, :revoke_and_end_in_tx, %{at: second})
             end)

    assert ended.revoked_at == first
    assert ended.ended_at == second

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(ended, :extend_in_tx, %{
                 expires_at: DateTime.add(session.expires_at, 3600),
                 revoked_at: nil,
                 ended_at: nil
               })
             end)

    assert MapSet.new(Enum.map(rejected.errors, & &1.input)) ==
             MapSet.new([:revoked_at, :ended_at])

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Session, session.id), ended)
  end

  test "a delivered logout cannot restart or consume another attempt", %{session: session} do
    delivery = delivery(session)
    now = DateTime.utc_now()

    assert {:ok, claimed} =
             Repo.transact(fn -> Ankole.Ash.update(delivery, :claim_in_tx, %{at: now}) end)

    assert claimed.attempt_count == 1

    assert {:ok, delivered} =
             Repo.transact(fn -> Ankole.Ash.update(claimed, :acknowledge_in_tx, %{at: now}) end)

    assert delivered.status == :delivered
    assert delivered.delivered_at == now
    jobs = Repo.aggregate(Oban.Job, :count)
    assert {:ok, repeated} = Logout.retry(delivered.id)
    assert_persisted_equal(repeated, delivered)
    assert Repo.aggregate(Oban.Job, :count) == jobs

    assert {:error, _} =
             Repo.transact(fn ->
               Ankole.Ash.update(delivered, :restart_in_tx, %{
                 deadline: DateTime.add(now, 3600),
                 next_attempt_at: now
               })
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(LogoutDelivery, delivered.id), delivered)
  end

  test "logout confirmation cannot replace its browser proof or be cleared", %{session: session} do
    request = request(session)

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(request, :confirm_in_tx, %{
                 browser_id: Ankole.Ecto.UUIDv7.autogenerate(),
                 browser_revision: request.browser_revision + 1
               })
             end)

    assert MapSet.new(Enum.map(rejected.errors, & &1.input)) ==
             MapSet.new([:browser_id, :browser_revision])

    assert {:ok, confirmed} =
             Repo.transact(fn -> Ankole.Ash.update(request, :confirm_in_tx, %{}) end)

    assert confirmed.confirmed_at

    assert {:error, _} =
             Repo.transact(fn -> Ankole.Ash.update(confirmed, :confirm_in_tx, %{}) end)

    assert {:error, _} =
             Repo.transact(fn -> Ankole.Ash.destroy(confirmed, :cancel_in_tx) end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(LogoutRequest, request.id), confirmed)
  end

  test "a Session cannot bind one browser to another browser's authentication", %{
    session: session
  } do
    {:ok, browser} = Ankole.BrowserSessions.create()

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Other RP",
        type: "public",
        enabled: true,
        allowed_models: %{},
        allowed_group_ids: [],
        redirect_uris: ["https://other.example/callback"],
        scopes: ["openid"]
      })

    attrs =
      session
      |> Map.take([
        :client_id,
        :principal_uid,
        :browser_id,
        :authentication_id,
        :authentication_revision,
        :access_version,
        :provider_id,
        :auth_time,
        :expires_at
      ])
      |> Map.put(:client_id, client.id)

    assert {:error, error} =
             Repo.transact(fn ->
               Ankole.Ash.create(
                 Session,
                 :authorize_in_tx,
                 Map.put(attrs, :browser_id, browser.id)
               )
             end)

    assert errors_on(error).authentication_id == ["does not exist"]
    assert Repo.aggregate(Session, :count) == 1

    assert {:ok, authorized} =
             Repo.transact(fn -> Ankole.Ash.create(Session, :authorize_in_tx, attrs) end)

    assert authorized.browser_id == session.browser_id
    assert authorized.authentication_id == session.authentication_id
  end

  test "PostgreSQL rejects invalid Session versions and logout counters", %{session: session} do
    delivery = delivery(session)
    request = request(session)

    for {sql, id, constraint} <- [
          {"UPDATE oidc_sessions SET access_version = 0", session.id,
           "oidc_sessions_access_version_positive"},
          {"UPDATE oidc_sessions SET authentication_revision = 0", session.id,
           "oidc_sessions_authentication_revision_positive"},
          {"UPDATE oidc_logout_requests SET browser_revision = -1", request.id,
           "oidc_logout_requests_browser_revision_nonnegative"},
          {"UPDATE oidc_logout_deliveries SET attempt_count = -1", delivery.id,
           "oidc_logout_deliveries_attempt_count_nonnegative"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            sql <> " WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid",
            [Repo.tenant_id!(), id],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == constraint
    end
  end

  defp delivery(session) do
    {:ok, delivery} =
      Repo.transact(fn ->
        Ankole.Ash.create(LogoutDelivery, :enqueue_in_tx, %{
          session_id: session.id,
          endpoint: "https://rp.example/logout",
          deadline: DateTime.add(DateTime.utc_now(), 3600)
        })
      end)

    delivery
  end

  defp request(session) do
    browser = Repo.get!(Ankole.BrowserSessions.Session, session.browser_id)

    {:ok, request} =
      Repo.transact(fn ->
        Ankole.Ash.create(LogoutRequest, :prepare_in_tx, %{
          browser_id: browser.id,
          browser_revision: browser.revision,
          expires_at: DateTime.add(DateTime.utc_now(), 600)
        })
      end)

    request
  end
end
