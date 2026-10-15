defmodule Ankole.PrincipalUidRaceIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.Principals
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.Principal

  setup %{tenant: tenant} do
    assert :ok = Ankole.Tenants.ensure_scaffold(tenant)

    on_exit(
      Repo.bind_tenant(fn ->
        assert {:ok, _} = Ankole.Tenants.delete(tenant)
        job = %Oban.Job{args: %{"tenant_id" => tenant.id}}

        Enum.reduce_while(1..30, nil, fn _, _ ->
          case Ankole.Tenants.Jobs.Delete.run(job) do
            :ok -> {:halt, :ok}
            {:snooze, _} -> {:cont, nil}
            error -> flunk("Tenant cleanup failed: #{inspect(error)}")
          end
        end)

        refute Repo.get(Ankole.Tenants.Tenant, tenant.id)

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'tenant_id'", j.args) == ^tenant.id)
        )
      end)
    )

    :ok
  end

  test "two observations of the same provider subject converge on one opaque Principal" do
    external_id = "race-subject-#{System.unique_integer([:positive])}"
    results = observe_concurrently(["slack-race", "slack-race"], external_id)
    assert Enum.all?(results, &match?({:ok, _observed}, &1))
    [uid] = Enum.map(results, fn {:ok, observed} -> observed.principal.uid end) |> Enum.uniq()
    assert {:ok, ^uid} = Ecto.UUID.cast(uid)
    refute uid == external_id

    assert Repo.aggregate(from(principal in Principal, where: principal.uid == ^uid), :count) == 1

    assert Repo.aggregate(
             from(identity in ExternalIdentity, where: identity.principal_uid == ^uid),
             :count
           ) == 1
  end

  test "different providers observing the same external identifier create distinct opaque Principals" do
    external_id = "race-subject-#{System.unique_integer([:positive])}"
    results = observe_concurrently(["slack-race", "dingtalk-race"], external_id)
    assert Enum.all?(results, &match?({:ok, _observed}, &1))
    uids = Enum.map(results, fn {:ok, observed} -> observed.principal.uid end) |> Enum.uniq()
    assert length(uids) == 2

    for uid <- uids do
      assert {:ok, ^uid} = Ecto.UUID.cast(uid)
      refute uid == external_id
    end

    assert Repo.aggregate(from(principal in Principal, where: principal.uid in ^uids), :count) ==
             2

    assert Repo.aggregate(
             from(identity in ExternalIdentity, where: identity.principal_uid in ^uids),
             :count
           ) == 2
  end

  defp observe_concurrently(providers, external_id) do
    providers
    |> Enum.map(fn provider ->
      Task.async(
        Repo.bind_tenant(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Principals.upsert_platform_subject_human(%{
              provider: provider,
              external_id: external_id,
              display_name: provider
            })
          end)
        end)
      )
    end)
    |> Task.await_many(30_000)
  end
end
