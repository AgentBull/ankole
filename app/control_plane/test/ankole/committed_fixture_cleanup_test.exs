defmodule Ankole.CommittedFixtureCleanupTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.{DataCase, Repo, Tenants}
  alias Ankole.AgentWorkers.Providers, as: WorkerProviders
  alias Ankole.AIGateway.{ModelProfiles, ProviderConfigs}

  setup %{pool: pool} do
    schemas = [Tenants.Tenant, WorkerProviders.Provider, ProviderConfigs.Provider]

    original =
      Sandbox.unboxed_run(Repo, fn ->
        Map.new(schemas, &{&1, Repo.all(from row in &1, order_by: row.id, select: row.id)})
      end)

    # Registered first so this assertion runs after DataCase's real teardown.
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for {schema, ids} <- original do
          assert Repo.all(from row in schema, order_by: row.id, select: row.id) == ids
        end
      end)
    end)

    if pool == DBConnection.ConnectionPool do
      Ankole.E2E.Harness.start_committed_repo!()
    end

    DataCase.setup_sandbox(%{sandbox: false})
    tenant = DataCase.create_committed_tenant()
    Repo.put_tenant_id(tenant.id)
    %{tenant: tenant}
  end

  for pool <- [DBConnection.Ownership, DBConnection.ConnectionPool] do
    @tag pool: pool
    test "committed tenant and Provider fixtures are removed with #{inspect(pool)}", %{
      tenant: tenant
    } do
      %{principal: agent} = Ankole.SessionsCase.agent_fixture()
      {:ok, profile} = ModelProfiles.get_model_profile(agent.uid, "primary")

      Task.async(fn ->
        Repo.with_tenant(tenant.id, fn ->
          assert Repo.get_by!(Ankole.Principals.Agent, uid: agent.uid)
          assert {:ok, _} = ProviderConfigs.fetch_provider(profile["provider_id"])
        end)
      end)
      |> Task.await()
    end
  end
end
