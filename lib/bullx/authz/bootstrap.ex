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

      {:error, {conflict, group}}
      when conflict in [:conflicting_admin_group, :conflicting_all_humans_group] ->
        Logger.warning(
          "BullX.AuthZ bootstrap found #{conflicting_group_name(conflict)} group conflict: #{inspect(Map.take(group, [:id, :built_in]))}"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "BullX.AuthZ bootstrap failed to reconcile admin membership: #{inspect(changeset.errors)}"
        )

      {:error, reason} ->
        raise "BullX.AuthZ bootstrap failed: #{inspect(reason)}"
    end
  end

  defp conflicting_group_name(:conflicting_admin_group), do: "admin"
  defp conflicting_group_name(:conflicting_all_humans_group), do: "all_humans"
end
