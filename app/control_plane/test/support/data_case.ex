defmodule Ankole.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

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

    on_exit(fn ->
      Ankole.Repo.with_tenant(tenant.id, fn ->
        {:ok, :ok} = Ankole.Pod.BaseRepo.delete_tenant(tenant.base_db_id)
      end)
    end)

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
          :ok = Ankole.Pod.Access.initialize_space()
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

    case Keyword.fetch!(opts, :pool) do
      DBConnection.Ownership ->
        :ok = Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :auto)

        on_exit(fn ->
          Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
          Ankole.AppConfigure.Cache.clear_for_test()
        end)

      DBConnection.ConnectionPool ->
        :ok
    end
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
