defmodule Ankole.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias Ankole.{Repo, Tenants}
  alias Ankole.AgentWorkers.Providers, as: WorkerProviders
  alias Ankole.AIGateway.ProviderConfigs

  using do
    quote do
      alias Ankole.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Ankole.DataCase

      use Oban.Testing, repo: Ankole.Repo
    end
  end

  setup tags do
    Ankole.DataCase.setup_sandbox(tags)

    tenant =
      if tags[:sandbox] == false do
        create_committed_tenant()
      else
        create_tenant()
      end

    Ankole.Repo.put_tenant_id(tenant.id)
    {:ok, _system} = Ankole.Principals.ensure_system_principals_in_tx()

    if tags[:sandbox] != false do
      on_exit(fn ->
        Ankole.Repo.with_tenant(tenant.id, fn ->
          {:ok, :ok} = Ankole.Pod.BaseRepo.delete_tenant(tenant.base_db_id)
        end)
      end)
    end

    {:ok, tenant: tenant}
  end

  @doc "Compares every persisted schema field without framework bookkeeping."
  def assert_persisted_equal(actual, expected) when is_list(actual) and is_list(expected) do
    assert Enum.map(actual, &persisted_fields/1) == Enum.map(expected, &persisted_fields/1)
  end

  def assert_persisted_equal(actual, expected) do
    assert persisted_fields(actual) == persisted_fields(expected)
  end

  defp persisted_fields(%schema{} = record),
    do: {schema, Map.take(record, schema.__schema__(:fields))}

  @doc """
  Creates a committed tenant through its lifecycle owner.

  Tests also call it inside their own transaction, so it uses the composition
  function, not the top-level action.
  """
  def create_committed_tenant(attrs \\ %{}) do
    attrs = Map.merge(tenant_attributes(), attrs)
    {:ok, tenant} = Ankole.Repo.transact(fn -> Ankole.Tenants.create_in_tx(attrs) end)
    tenant
  end

  @doc "Creates an isolated tenant without changing site configuration."
  def create_tenant(attrs \\ %{}) do
    {:ok, tenant} =
      Ankole.Repo.transact(fn ->
        {:ok, tenant} =
          Ankole.Ash.create(
            Ankole.Tenants.Tenant,
            :create_in_tx,
            Map.merge(tenant_attributes(), attrs)
          )

        Ankole.Repo.with_tenant(tenant.id, fn ->
          :ok = Ankole.Files.Access.initialize_space()
          {:ok, _system} = Ankole.Principals.ensure_system_principals_in_tx()
        end)

        {:ok, tenant}
      end)

    tenant
  end

  defp tenant_attributes do
    id = Ankole.Ecto.UUIDv7.autogenerate()
    {:ok, shard} = Ankole.Pod.BaseCluster.allocate(id)

    %{
      id: id,
      base_db_id: shard,
      slug: "test-" <> Ankole.Ecto.UUIDv7.autogenerate(),
      display_name: "Test tenant"
    }
  end

  @doc "Deletes a committed tenant through its lifecycle owner."
  def cleanup_tenant!(tenant) do
    assert {:ok, _} = Ankole.Tenants.delete(tenant)
    job = %Oban.Job{args: %{"tenant_id" => tenant.id}}

    Enum.reduce_while(1..30, nil, fn _, _ ->
      case Ankole.Tenants.Jobs.Delete.run(job) do
        :ok -> {:halt, :ok}
        {:snooze, _} -> {:cont, nil}
        error -> flunk("Tenant cleanup failed: #{inspect(error)}")
      end
    end)

    refute Ankole.Repo.get(Ankole.Tenants.Tenant, tenant.id)

    Ankole.Repo.delete_all(
      from(j in Oban.Job, where: fragment("?->>'tenant_id'", j.args) == ^tenant.id)
    )
  end

  @doc "Selects the privileged tenant for a serial test of site administration."
  def set_privileged_tenant(%Ankole.Tenants.Tenant{} = tenant) do
    {:ok, _} = Ankole.AppConfigure.put_global_by_key("tenants.privileged_tenant_id", tenant.id)
    :ok
  end

  def setup_sandbox(%{sandbox: false}) do
    %{opts: opts} = Ecto.Adapter.lookup_meta(Ankole.Repo)
    sandbox? = Keyword.fetch!(opts, :pool) == DBConnection.Ownership

    if sandbox?, do: Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :auto)

    fixtures = committed_fixtures()
    drivers = Ankole.SessionsCase.driver_pids()
    previews = Ankole.SessionsCase.preview_handler_pids()

    on_exit(fn ->
      try do
        Ankole.SessionsCase.stop_new_drivers(drivers)
        Ankole.SessionsCase.stop_new_preview_handlers(previews)
        cleanup_committed_fixtures!(fixtures)
      after
        if sandbox?, do: Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
        Ankole.AppConfigure.Cache.clear_for_test()
      end
    end)
  end

  def setup_sandbox(tags) do
    opts =
      [shared: not tags[:async]]
      |> maybe_put_ownership_timeout(tags[:ownership_timeout])

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Ankole.Repo, opts)
    drivers = if not tags[:async], do: Ankole.SessionsCase.driver_pids()
    previews = if not tags[:async], do: Ankole.SessionsCase.preview_handler_pids()

    on_exit(fn ->
      if drivers do
        Ankole.SessionsCase.stop_new_drivers(drivers)
        Ankole.SessionsCase.stop_new_preview_handlers(previews)
      end

      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      # The global cache is shared by all tenants and outlives the rollback of a test.
      Ankole.AppConfigure.Cache.clear_for_test()
    end)
  end

  # Real-transaction tests share a serial database. Their own on_exit callbacks
  # stop external resources first; this last callback owns the committed rows
  # that ordinary SQL Sandbox rollback would otherwise remove.
  defp committed_fixtures do
    for schema <- [Tenants.Tenant, WorkerProviders.Provider, ProviderConfigs.Provider],
        into: %{} do
      {schema, Repo.all(from row in schema, select: row.id)}
    end
  end

  defp cleanup_committed_fixtures!(fixtures) do
    for tenant <- new_fixture_rows(Tenants.Tenant, fixtures) do
      Repo.with_tenant(tenant.id, fn ->
        # Fixture Workers have no external backend. Real Worker tests finish
        # their platform cleanup in their own earlier on_exit callback.
        fixture_agents =
          Repo.all(
            from worker in Ankole.AgentWorkers.AgentWorker,
              where: like(worker.provider_id, "fixture-worker-%"),
              select: worker.agent_uid
          )

        Enum.each(fixture_agents, &Ankole.PrincipalsFixtures.delete_agent_fixture_rows/1)
        cleanup_tenant!(tenant)
      end)
    end

    for provider <- new_fixture_rows(WorkerProviders.Provider, fixtures) do
      assert {:ok, _} = WorkerProviders.delete(provider.provider_id)
    end

    for provider <- new_fixture_rows(ProviderConfigs.Provider, fixtures) do
      if is_nil(provider.disabled_at) do
        assert {:ok, _} = ProviderConfigs.delete_provider(provider.provider_id)
      end

      assert {:ok, _} = ProviderConfigs.delete_provider(provider.provider_id)
    end
  end

  defp new_fixture_rows(schema, fixtures) do
    previous_ids = Map.fetch!(fixtures, schema)
    Repo.all(from row in schema, where: row.id not in ^previous_ids)
  end

  defp maybe_put_ownership_timeout(opts, timeout) when is_integer(timeout) and timeout > 0,
    do: Keyword.put(opts, :ownership_timeout, timeout)

  defp maybe_put_ownership_timeout(opts, _timeout), do: opts

  def errors_on(%module{} = error) when module in [Ash.Changeset, Ash.Error.Invalid] do
    error
    |> Ankole.Ash.validation_details()
    |> Enum.group_by(
      fn
        %{path: ""} -> :base
        %{path: field} -> String.to_existing_atom(field)
      end,
      & &1.message
    )
  end

  def errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
