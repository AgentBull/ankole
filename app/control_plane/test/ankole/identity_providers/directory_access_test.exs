defmodule Ankole.IdentityProviders.DirectoryAccessTest do
  use Ankole.DataCase, async: false
  alias Ankole.{AuthZ, Principals, Repo}
  alias Ankole.IdentityProviders.{DirectoryAccess, DirectoryEvent}
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Principals.HumanAccess

  test "a reliable object deletion resolves aliases, disables the last admin, and is idempotent" do
    {:ok, person} =
      IdentityProvider.upsert_user("lark-main", %{
        "user_id" => "employee-1",
        "open_id" => "open-1",
        "email" => "person@example.test"
      })

    {:ok, _} = AuthZ.root_init_admin(person.principal.uid)

    event = %FeishuOpenAPI.Event{
      id: "departure-1",
      type: "contact.user.deleted_v3",
      created_at: DateTime.utc_now(),
      content: %{"object" => %{"open_id" => "open-1"}},
      raw: %{}
    }

    consumer = [%{kind: :identity_provider, provider_id: "lark-main"}]

    assert {:ok, [%{status: :processed}]} =
             IdentityProvider.handle_contact_event(event.type, event, consumer)

    assert {:ok, %{status: :disabled, access_version: version}} =
             Principals.get_principal(person.principal.uid)

    assert version == person.principal.access_version + 1
    assert {:ok, [_]} = IdentityProvider.handle_contact_event(event.type, event, consumer)
    assert Repo.aggregate(DirectoryEvent, :count) == 1
    assert length(HumanAccess.history(person.principal.uid)) == 1
  end

  test "unknown departure blocks later creation through any observed alias until reviewed" do
    attrs = %{
      event_id: "unknown-departure",
      event_type: "contact.user.deleted_v3",
      external_ids: ["new-open"],
      reason: "departure",
      provider_time: DateTime.utc_now()
    }

    assert {:ok, event} = DirectoryAccess.receive_event("lark-main", attrs)
    assert event.status == :review_required

    assert {:error, :provider_identity_requires_review} =
             IdentityProvider.upsert_user("lark-main", %{
               "email" => "new@example.test",
               "open_id" => "new-open"
             })

    assert {:ok, _} =
             DirectoryAccess.review_event(
               event.id,
               nil,
               "Verified that the provider ID was reassigned",
               :dismiss
             )

    assert {:ok, _} =
             IdentityProvider.upsert_user("lark-main", %{
               "email" => "new@example.test",
               "open_id" => "new-open"
             })
  end

  test "frozen users cannot enter through the login upsert and current healthy state does not restore them" do
    {:ok, person} =
      IdentityProvider.upsert_user("lark-main", %{
        "user_id" => "frozen",
        "status" => %{"is_frozen" => true}
      })

    assert person.principal.status == :disabled

    {:ok, refreshed} =
      IdentityProvider.upsert_user("lark-main", %{
        "user_id" => "frozen",
        "status" => healthy_status()
      })

    assert refreshed.principal.status == :disabled
    state = snapshot([{person.principal.uid, :healthy}])
    assert state.status == :review_required
    [restriction] = HumanAccess.restrictions(person.principal.uid)
    assert restriction.recovery_verified_at
    assert {:ok, %{status: :disabled}} = Principals.get_principal(person.principal.uid)
  end

  test "missing members require baseline approval; complete later snapshots can remove them" do
    first = person("first")
    second = person("second")
    baseline = snapshot([{first.uid, :healthy}, {second.uid, :healthy}])
    assert baseline.status == :review_required

    {:ok, _} =
      DirectoryAccess.approve_snapshot(
        "lark-main",
        baseline.snapshot_fingerprint,
        nil,
        "Verified contact scope is the admission scope",
        false
      )

    current = snapshot([{first.uid, :healthy}], maximum_removal_percent: 60)
    assert current.status == :healthy
    assert {:ok, %{status: :disabled}} = Principals.get_principal(second.uid)
    assert [%{reason: "directory_removal"}] = HumanAccess.restrictions(second.uid)
  end

  test "empty and large reductions retain candidates across retries and need exact reviewed evidence" do
    first = person("first")
    second = person("second")
    baseline = snapshot([{first.uid, :healthy}, {second.uid, :healthy}])

    {:ok, _} =
      DirectoryAccess.approve_snapshot(
        "lark-main",
        baseline.snapshot_fingerprint,
        nil,
        "Verified scope",
        false
      )

    reduced = snapshot([{first.uid, :healthy}])
    assert reduced.status == :review_required
    assert reduced.missing_uids == [second.uid]
    repeated = snapshot([{first.uid, :healthy}])
    assert repeated.missing_uids == [second.uid]

    assert {:error, :directory_review_changed} =
             DirectoryAccess.approve_snapshot(
               "lark-main",
               reduced.snapshot_fingerprint,
               nil,
               "Stale review",
               true
             )

    assert {:ok, %{status: :active}} = Principals.get_principal(second.uid)
    empty = snapshot([])
    assert Enum.sort(empty.missing_uids) == Enum.sort([first.uid, second.uid])
  end

  test "a newer provider event prevents an older snapshot from removing missing people" do
    person = person("concurrent")
    baseline = snapshot([{person.uid, :healthy}])

    {:ok, _} =
      DirectoryAccess.approve_snapshot(
        "lark-main",
        baseline.snapshot_fingerprint,
        nil,
        "Verified scope",
        false
      )

    {:ok, ticket} = DirectoryAccess.begin_sync("lark-main")

    {:ok, _} =
      DirectoryAccess.receive_event("lark-main", %{
        event_id: "scope-event",
        event_type: "contact.scope.updated_v3",
        external_ids: [],
        reason: nil,
        provider_time: DateTime.utc_now()
      })

    assert {:ok, :superseded} =
             DirectoryAccess.finish_sync(ticket, "scope", [],
               admission_scope: "contact",
               maximum_removal_percent: 100
             )

    assert {:ok, %{status: :active}} = Principals.get_principal(person.uid)
    assert DirectoryAccess.state("lark-main").approved_scope_fingerprint == nil
  end

  test "failed collection records health without changing membership or enabling restoration" do
    person = person("failed")
    baseline = snapshot([{person.uid, :healthy}])
    {:ok, ticket} = DirectoryAccess.begin_sync("lark-main")
    assert {:error, :partial_page} = DirectoryAccess.fail_sync(ticket, :partial_page)
    state = DirectoryAccess.state("lark-main")
    assert state.status == :failed
    assert state.member_uids == baseline.member_uids
    assert state.last_success_at == baseline.last_success_at
    assert {:ok, %{status: :active}} = Principals.get_principal(person.uid)
  end

  defp person(id) do
    {:ok, person} = IdentityProvider.upsert_user("lark-main", %{"user_id" => id})
    person.principal
  end

  defp snapshot(observations, opts \\ []) do
    {:ok, ticket} = DirectoryAccess.begin_sync("lark-main")

    {:ok, state} =
      DirectoryAccess.finish_sync(
        ticket,
        "scope",
        observations,
        Keyword.merge([admission_scope: "contact", maximum_removal_percent: 20], opts)
      )

    state
  end

  defp healthy_status, do: %{"is_frozen" => false, "is_exited" => false, "is_resigned" => false}
end
