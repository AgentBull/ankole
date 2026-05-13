defmodule BullX.AuthZ.Bootstrap do
  @moduledoc false

  use Task

  alias BullX.AuthZ

  require Logger

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:restart, :transient)
  end

  def run do
    case AuthZ.bootstrap_storage_ready?() do
      true ->
        reconcile()

      false ->
        Logger.warning("BullX.AuthZ bootstrap skipped because required tables do not exist")
    end
  end

  defp reconcile do
    case AuthZ.reconcile_bootstrap_admin_membership() do
      :ok ->
        :ok

      {:error, {:conflicting_admin_group, group}} ->
        Logger.warning(
          "BullX.AuthZ bootstrap found conflicting admin group: #{inspect(Map.take(group, [:id, :built_in]))}"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "BullX.AuthZ bootstrap failed to reconcile admin membership: #{inspect(changeset.errors)}"
        )

      {:error, reason} ->
        raise "BullX.AuthZ bootstrap failed: #{inspect(reason)}"
    end
  end
end
