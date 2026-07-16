defmodule Ankole.SubagentDelegations.Retention do
  @moduledoc false

  import Ecto.Query

  alias Ankole.Repo
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.WorkerFiles

  @terminal_statuses ~w(succeeded failed stopped)
  @batch_size 100

  @spec cleanup_expired_workspaces(DateTime.t()) :: %{
          cleaned: non_neg_integer(),
          deferred: non_neg_integer()
        }
  def cleanup_expired_workspaces(now \\ DateTime.utc_now(:microsecond)) do
    candidates =
      Delegation
      |> where([delegation], delegation.runtime == "deep_research")
      |> where([delegation], delegation.status in @terminal_statuses)
      |> where([delegation], not is_nil(delegation.completed_at))
      |> where([delegation], is_nil(delegation.workspace_cleaned_at))
      |> where(
        [delegation],
        fragment(
          "? + (? * interval '1 day') <= ?",
          delegation.completed_at,
          delegation.workspace_retention_days,
          ^now
        )
      )
      |> order_by([delegation], asc: delegation.completed_at, asc: delegation.id)
      |> limit(@batch_size)
      |> Repo.all()

    Enum.reduce(candidates, %{cleaned: 0, deferred: 0}, fn delegation, counts ->
      if managed_workspace?(delegation) do
        cleanup(delegation, now, counts)
      else
        counts
      end
    end)
  end

  defp cleanup(%Delegation{} = delegation, now, counts) do
    case WorkerFiles.delete("user_files", "research/#{delegation.id}", recursive: true) do
      {:ok, _result} ->
        case delegation |> Ecto.Changeset.change(workspace_cleaned_at: now) |> Repo.update() do
          {:ok, _delegation} -> Map.update!(counts, :cleaned, &(&1 + 1))
          {:error, _changeset} -> Map.update!(counts, :deferred, &(&1 + 1))
        end

      {:error, _reason} ->
        Map.update!(counts, :deferred, &(&1 + 1))
    end
  end

  defp managed_workspace?(%Delegation{} = delegation),
    do: delegation.workdir == "/workspace/user-files/research/#{delegation.id}"
end
