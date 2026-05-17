defmodule BullX.EventBus.Repair do
  @moduledoc false

  import Ecto.Query

  alias BullX.EventBus.TargetSession
  alias BullX.EventBus.TargetSession.Job
  alias BullX.Repo

  @worker "BullX.EventBus.TargetSession.Worker"
  @open_job_states ["available", "scheduled", "executing", "retryable"]

  @spec ensure_active_target_session_jobs() :: :ok | {:error, term()}
  def ensure_active_target_session_jobs do
    with :ok <- ensure_jobs_for_active_sessions(),
         :ok <- cancel_orphan_jobs() do
      :ok
    end
  end

  defp ensure_jobs_for_active_sessions do
    TargetSession
    |> where([s], s.status == :active)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn session, :ok ->
      case Job.ensure(session) do
        {:ok, _session} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cancel_orphan_jobs do
    Oban.Job
    |> where([j], j.worker == ^@worker)
    |> where([j], j.state in ^@open_job_states)
    |> Repo.all()
    |> Enum.each(&cancel_if_orphan/1)

    :ok
  end

  defp cancel_if_orphan(%Oban.Job{args: %{"target_session_id" => id}} = job) do
    case Repo.get(TargetSession, id) do
      nil -> Oban.cancel_job(job.id)
      %TargetSession{} -> :ok
    end
  end

  defp cancel_if_orphan(_job), do: :ok
end
