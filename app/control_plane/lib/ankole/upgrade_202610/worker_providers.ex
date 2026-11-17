defmodule Ankole.Upgrade202610.WorkerProviders do
  @moduledoc """
  Imports bootstrap providers and assigns legacy 1.x Agents during `upgrade_from_1x`.

  Sunset: Remove at 2.0.0 GA (`Ankole.AgentWorkers.BootstrapSeed` owns standard 2.0 seeding).
  """

  alias Ankole.AgentWorkers.{BootstrapSeed, Providers}
  alias Ankole.Errors
  alias Ankole.Repo

  def import_file(path) do
    Repo.transact_top_level(fn -> import_in_tx(path) end)
    |> Errors.reason()
  end

  @doc "Imports the seed file in the caller's transaction when no provider exists."
  def import_in_tx(path) do
    Providers.lock_registry(:exclusive)

    cond do
      Providers.list() != [] ->
        :ok

      is_nil(path) ->
        :ok

      true ->
        with {:ok, legacy_id} <-
               BootstrapSeed.import_entries_in_tx(path, enforce_single_legacy?: true),
             {:ok, ^legacy_id} <- select_legacy_provider(legacy_id) do
          if legacy_id, do: assign_legacy_provider_in_tx(legacy_id), else: :ok
        end
    end
  end

  defp select_legacy_provider(nil), do: {:ok, nil}
  defp select_legacy_provider(id), do: Providers.select_in_tx(id)

  @spec assign_legacy_provider_in_tx(String.t()) :: :ok | {:error, term()}
  defp assign_legacy_provider_in_tx(provider_id) do
    workers = Repo.across_tenants(&Ankole.AgentWorkers.lock_unassigned_workers_in_tx/0)

    Enum.reduce_while(workers, :ok, fn worker, :ok ->
      Repo.with_tenant(worker.tenant_id, fn ->
        Ankole.AgentWorkers.assign_worker_provider(worker, %{provider_id: provider_id})
      end)
      |> case do
        {:ok, _updated} -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end
end
