defmodule Ankole.BrowserSessionsTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, BrowserSessions}
  alias Ankole.Principals.HumanAccess

  test "the first completed flow wins and stale references cannot read its identity" do
    %{principal: first} = human_fixture()
    %{principal: second} = human_fixture()
    {:ok, browser} = BrowserSessions.create()
    reference = BrowserSessions.reference(browser)
    first_flow = flow(reference, :oauth)
    second_flow = flow(reference, :oauth)

    assert {:ok, completed} =
             BrowserSessions.complete_login(reference, first_flow.id, auth(first))

    assert {:error, :browser_session_expired} =
             BrowserSessions.complete_login(reference, second_flow.id, auth(second))

    assert nil == BrowserSessions.authentication(reference, :oauth)
    current = BrowserSessions.reference(completed.browser)
    assert %{"principal_uid" => uid} = BrowserSessions.authentication(current, :oauth)
    assert uid == first.uid

    assert {:error, :login_expired} =
             BrowserSessions.complete_login(current, first_flow.id, auth(first))
  end

  test "explicit Console and OAuth identity changes remove the conflicting context" do
    %{principal: admin} = human_fixture()
    %{principal: human} = human_fixture()
    {:ok, _} = AuthZ.root_init_admin(admin.uid)
    {:ok, browser} = BrowserSessions.create()
    ref = BrowserSessions.reference(browser)
    {:ok, completed} = BrowserSessions.complete_login(ref, flow(ref, :oauth).id, auth(human))
    ref = BrowserSessions.reference(completed.browser)
    {:ok, completed} = BrowserSessions.complete_login(ref, flow(ref, :console).id, auth(admin))
    ref = BrowserSessions.reference(completed.browser)
    assert nil == BrowserSessions.authentication(ref, :oauth)
    assert %{"principal_uid" => uid} = BrowserSessions.authentication(ref, :console)
    assert uid == admin.uid
    {:ok, completed} = BrowserSessions.complete_login(ref, flow(ref, :oauth).id, auth(human))
    ref = BrowserSessions.reference(completed.browser)
    assert nil == BrowserSessions.authentication(ref, :console)
    assert %{"principal_uid" => uid} = BrowserSessions.authentication(ref, :oauth)
    assert uid == human.uid
  end

  test "logout ends pending callbacks and password changes without executing their writes" do
    %{principal: human} = human_fixture()
    {:ok, browser} = BrowserSessions.create()
    ref = BrowserSessions.reference(browser)
    transaction = flow(ref, :oauth)
    assert {:ok, _} = BrowserSessions.put_password_ticket(ref, transaction.id, auth(human))
    assert {:ok, _} = BrowserSessions.logout(ref)

    assert {:error, :browser_session_expired} =
             BrowserSessions.complete_login(ref, transaction.id, auth(human), fn ->
               flunk("a stale password transaction must not write")
             end)

    assert nil == BrowserSessions.authentication(ref, :oauth)
  end

  test "authorization completion belongs to one request and is consumed once" do
    %{principal: human} = human_fixture()
    {:ok, browser} = BrowserSessions.create()
    ref = BrowserSessions.reference(browser)

    request = %{
      "client_id" => "client",
      "state" => "state",
      "nonce" => "nonce",
      "code_challenge" => "pkce"
    }

    transaction = flow(ref, :oauth, request)
    {:ok, completed} = BrowserSessions.complete_login(ref, transaction.id, auth(human))
    ref = BrowserSessions.reference(completed.browser)

    assert {:ok, ^request} =
             BrowserSessions.consume_authorization(ref, transaction.id, fn params,
                                                                           authentication ->
               assert authentication["principal_uid"] == human.uid
               {:ok, params}
             end)

    assert {:error, :login_expired} =
             BrowserSessions.consume_authorization(ref, transaction.id, fn _, _ ->
               flunk("an authorization transaction is one-use")
             end)
  end

  test "a login started before account revocation cannot finish after recovery" do
    %{principal: human} = human_fixture()
    {:ok, browser} = BrowserSessions.create()
    ref = BrowserSessions.reference(browser)
    transaction = flow(ref, :oauth)
    {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    [restriction] = HumanAccess.restrictions(human.uid)
    {:ok, _} = HumanAccess.clear_restriction(human.uid, restriction.id, nil, "verified", "clear")
    {:ok, review} = AuthZ.restoration_review(human.uid)

    {:ok, restored} =
      HumanAccess.restore(human.uid, review.fingerprint, nil, "verified", "restore")

    assert {:error, :human_access_revoked} =
             BrowserSessions.complete_login(ref, transaction.id, auth(restored))

    assert {:ok, _} = BrowserSessions.complete_login(ref, flow(ref, :oauth).id, auth(restored))
  end

  test "a provider callback requires its exact browser, provider and state" do
    {:ok, browser} = BrowserSessions.create()
    ref = BrowserSessions.reference(browser)
    {:ok, transaction} = BrowserSessions.begin_login(ref, :oauth, %{})

    {:ok, _} =
      BrowserSessions.bind_provider(
        ref,
        transaction.id,
        "lark",
        "secret-state",
        "https://op.test/callback"
      )

    assert {:ok, _} = BrowserSessions.callback(ref, "lark", "secret-state")
    assert {:error, :login_expired} = BrowserSessions.callback(ref, "other", "secret-state")
    {:ok, other} = BrowserSessions.create()

    assert {:error, :login_expired} =
             BrowserSessions.callback(BrowserSessions.reference(other), "lark", "secret-state")
  end

  defp flow(ref, purpose, request \\ %{}) do
    {:ok, transaction} = BrowserSessions.begin_login(ref, purpose, request)
    {:ok, transaction} = BrowserSessions.bind_provider(ref, transaction.id, "local")
    transaction
  end

  defp auth(principal) do
    %{
      "principal_uid" => principal.uid,
      "access_version" => principal.access_version,
      "provider_id" => "local",
      "external_id" => principal.uid,
      "auth_time" => System.system_time(:second)
    }
  end
end
