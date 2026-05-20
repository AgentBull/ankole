defmodule BullX.EventBus.Cleanup do
  @moduledoc false

  import Ecto.Query

  alias BullX.EventBus.{Config, TargetSession, TargetSessionEntry}
  alias BullX.Repo

  @spec run(DateTime.t()) :: :ok
  def run(now \\ DateTime.utc_now(:microsecond)) do
    delete_retained_terminal(now)
    :ok
  end

  defp delete_retained_terminal(now) do
    cutoff = DateTime.add(now, -Config.target_session_runtime_retention_seconds(), :second)

    terminal_ids =
      TargetSession
      |> where([s], s.status in [:closed, :failed])
      |> where([s], s.updated_at < ^cutoff)
      |> select([s], s.id)
      |> Repo.all()

    case terminal_ids do
      [] ->
        :ok

      ids ->
        Repo.delete_all(from e in TargetSessionEntry, where: e.target_session_id in ^ids)
        Repo.delete_all(from s in TargetSession, where: s.id in ^ids)
        :ok
    end
  end
end
