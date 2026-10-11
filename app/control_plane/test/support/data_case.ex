defmodule Ankole.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Ankole.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

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
    %Ankole.Tenants.Tenant{}
    |> Ankole.Tenants.Tenant.changeset(%{
      slug: "test-" <> Ankole.Ecto.UUIDv7.autogenerate(),
      display_name: "Test tenant"
    })
    |> Ankole.Repo.insert!()
  end

  @doc "Selects the privileged tenant for a serial test of site administration."
  def set_privileged_tenant(%Ankole.Tenants.Tenant{} = tenant) do
    {:ok, _} = Ankole.AppConfigure.put_global_by_key("tenants.privileged_slug", tenant.slug)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
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
    drivers = if not tags[:async], do: Ankole.SignalsGateway.ActorRuntimeCase.driver_pids()

    on_exit(fn ->
      if drivers, do: Ankole.SignalsGateway.ActorRuntimeCase.stop_new_drivers(drivers)
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

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
