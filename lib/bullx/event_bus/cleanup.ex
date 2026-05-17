defmodule BullX.EventBus.Cleanup do
  @moduledoc false

  import Ecto.Query

  alias BullX.EventBus.{Config, TargetSession, TargetSessionEntry}
  alias BullX.EventBus.TargetSession.Resolver
  alias BullX.Repo

  @spec run(DateTime.t()) :: :ok
  def run(now \\ DateTime.utc_now(:microsecond)) do
    expire_overdue_active(now)
    delete_retained_terminal(now)
    :ok
  end

  defp expire_overdue_active(now) do
    TargetSession
    |> where([s], s.status == :active)
    |> Repo.all()
    |> Enum.each(&expire_if_overdue(&1, now))
  end

  defp expire_if_overdue(%TargetSession{} = session, now) do
    Repo.transaction(fn ->
      session.id
      |> lock_session_query()
      |> Repo.one()
      |> expire_locked_if_overdue(now)
    end)
  end

  defp expire_locked_if_overdue(nil, _now), do: :ok

  defp expire_locked_if_overdue(%TargetSession{status: status}, _now)
       when status in [:closed, :failed, :expired],
       do: :ok

  defp expire_locked_if_overdue(%TargetSession{} = session, now) do
    case Resolver.expiry_reason(session, now) do
      nil -> :ok
      reason -> expire(session, reason)
    end
  end

  defp expire(%TargetSession{} = session, reason) do
    session
    |> TargetSession.changeset(%{status: :expired, terminal_reason: reason})
    |> Repo.update()
    |> case do
      {:ok, _session} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp delete_retained_terminal(now) do
    cutoff = DateTime.add(now, -Config.target_session_runtime_retention_seconds(), :second)

    terminal_ids =
      TargetSession
      |> where([s], s.status in [:closed, :failed, :expired])
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

  defp lock_session_query(target_session_id) do
    TargetSession
    |> where([s], s.id == ^target_session_id)
    |> lock("FOR UPDATE")
  end
end
