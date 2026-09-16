defmodule Ankole.PrincipalUidRaceIntegrationTest do
  use Ankole.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.Principals
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.HumanUser
  alias Ankole.Principals.Principal

  test "two providers deriving one UID at the same time create one Principal and refuse the other" do
    uid = "race-subject-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(identity in ExternalIdentity, where: identity.principal_uid == ^uid))
        Repo.delete_all(from(human in HumanUser, where: human.principal_uid == ^uid))
        Repo.delete_all(from(principal in Principal, where: principal.uid == ^uid))
      end)
    end)

    results =
      ["slack-race", "dingtalk-race"]
      |> Enum.map(fn provider ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Principals.upsert_platform_subject_human(%{
              provider: provider,
              external_id: uid,
              display_name: provider
            })
          end)
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _observed}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :principal_uid_taken})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(principal in Principal, where: principal.uid == ^uid), :count) ==
               1

      assert Repo.aggregate(
               from(identity in ExternalIdentity, where: identity.principal_uid == ^uid),
               :count
             ) == 1
    end)
  end
end
