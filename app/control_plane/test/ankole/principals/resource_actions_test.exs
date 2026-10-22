defmodule Ankole.Principals.ResourceActionsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Principals.AccessEvent
  alias Ankole.Principals.Principal

  test "profile edits cannot change identity, revocation or status" do
    %{principal: principal} = human_fixture()

    for attrs <- [%{type: :system}, %{status: :disabled}, %{access_version: 100}] do
      assert {:error, %Ash.Error.Invalid{}} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.update(principal, :profile_in_tx, attrs)
               end)

      Ankole.DataCase.assert_persisted_equal(Repo.get!(Principal, principal.uid), principal)
    end
  end

  test "an idempotent audit entry preserves its first facts and permits a system actor" do
    %{principal: principal} = human_fixture()

    attrs = %{
      principal_uid: principal.uid,
      operation_id: "audit-operation",
      source: "work_cleanup",
      action: "stop_future_work",
      reason: "human_access_revoked",
      actor: nil,
      previous_status: :active,
      status: :active,
      access_version: principal.access_version,
      details: %{"stopped" => 1}
    }

    assert {:ok, {first, repeated}} =
             Repo.transact(fn _repo ->
               with {:ok, first} <- Ankole.Ash.create(AccessEvent, :record_once_in_tx, attrs),
                    {:ok, repeated} <-
                      Ankole.Ash.create(AccessEvent, :record_once_in_tx, %{
                        attrs
                        | details: %{"stopped" => 999}
                      }) do
                 {:ok, {first, repeated}}
               end
             end)

    assert repeated.id == first.id
    assert repeated.inserted_at == first.inserted_at
    assert repeated.details == %{"stopped" => 1}
    assert repeated.actor == nil
    assert Repo.get!(AccessEvent, first.id).details == %{"stopped" => 1}
  end

  test "audit JSON cannot persist a runtime value" do
    %{principal: principal} = human_fixture()

    assert {:error, %Ash.Error.Invalid{}} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(AccessEvent, :record_in_tx, %{
                 principal_uid: principal.uid,
                 operation_id: "bad-audit",
                 source: "work_cleanup",
                 action: "stop_future_work",
                 reason: "human_access_revoked",
                 previous_status: :active,
                 status: :active,
                 access_version: principal.access_version,
                 details: %{"process" => self()}
               })
             end)

    refute Repo.get_by(AccessEvent, operation_id: "bad-audit")
  end
end
