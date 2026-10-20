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
    tenant = create_tenant()
    Ankole.Repo.put_tenant_id(tenant.id)
    {:ok, tenant: tenant}
  end

  @doc "Creates an isolated tenant without changing site configuration."
  def create_tenant do
    {:ok, tenant} =
      Ankole.Repo.transact(fn repo ->
        tenant =
          %Ankole.Tenants.Tenant{}
          |> Ankole.Tenants.Tenant.changeset(%{
            slug: "test-" <> Ankole.Ecto.UUIDv7.autogenerate(),
            display_name: "Test tenant"
          })
          |> repo.insert!()

        Ankole.Repo.with_tenant(tenant.id, fn ->
          :ok = Ankole.Pod.Access.initialize_space(repo)
        end)

        {:ok, tenant}
      end)

    tenant
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
    # These serial integration tests need independent, committed transactions.
    # A shared owner would make every process wait on one connection.
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual) end)
  end

  def setup_sandbox(tags) do
    opts =
      [shared: not tags[:async]]
      |> maybe_put_ownership_timeout(tags[:ownership_timeout])

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Ankole.Repo, opts)
    drivers = if not tags[:async], do: Ankole.SessionsCase.driver_pids()

    on_exit(fn ->
      if drivers, do: Ankole.SessionsCase.stop_new_drivers(drivers)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
  end

  defp maybe_put_ownership_timeout(opts, timeout) when is_integer(timeout) and timeout > 0,
    do: Keyword.put(opts, :ownership_timeout, timeout)

  defp maybe_put_ownership_timeout(opts, _timeout), do: opts

  @doc """
  Lets the `Ankole.AppConfigure.Cache` process use the sandbox connection of the
  calling test.

  The cache is a long-lived process outside the test, so a test that makes the
  cache read the database must call this function first. Access stays opt-in:
  call it from the test or its setup block.
  """
  def allow_cache_database_access do
    case GenServer.whereis(Ankole.AppConfigure.Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Ankole.Repo, self(), pid)
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
