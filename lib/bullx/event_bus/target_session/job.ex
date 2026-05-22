defmodule BullX.EventBus.TargetSession.Job do
  @moduledoc false

  import Ecto.Query

  alias BullX.EventBus.{AppendFailed, TargetSession}
  alias BullX.EventBus.TargetSession.Worker
  alias BullX.Repo

  @spec ensure(TargetSession.t()) :: {:ok, TargetSession.t()} | {:error, AppendFailed.t()}
  def ensure(%TargetSession{} = session) do
    Repo.transaction(fn ->
      case lock_session(session.id) do
        %TargetSession{status: :active} = locked ->
          case ensure_locked(locked) do
            {:ok, session} -> session
            {:error, %AppendFailed{} = error} -> Repo.rollback(error)
          end

        %TargetSession{} = locked ->
          locked

        nil ->
          Repo.rollback(
            append_failed(:job_ensure_failed, %{"reason" => "target_session_missing"})
          )
      end
    end)
    |> case do
      {:ok, %TargetSession{} = session} -> {:ok, session}
      {:error, %AppendFailed{} = error} -> {:error, error}
    end
  end

  defp lock_session(target_session_id) do
    TargetSession
    |> where([s], s.id == ^target_session_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp ensure_locked(%TargetSession{oban_job_id: job_id} = session) when is_integer(job_id) do
    case job_state(job_id) do
      "executing" -> ensure_executing_job(session, job_id)
      state when state in ["available", "scheduled", "retryable"] -> {:ok, session}
      _missing_or_terminal -> insert_job(session)
    end
  end

  defp ensure_locked(%TargetSession{} = session), do: insert_job(session)

  defp ensure_executing_job(%TargetSession{} = session, job_id) do
    case Worker.registered?(session.id) do
      true ->
        {:ok, session}

      false ->
        :ok = Oban.cancel_job(job_id)
        insert_job(session)
    end
  end

  defp job_state(job_id) do
    Oban.Job
    |> where([j], j.id == ^job_id)
    |> select([j], j.state)
    |> Repo.one()
  end

  defp insert_job(%TargetSession{} = session) do
    changeset =
      Worker.new(%{"target_session_id" => session.id},
        unique: [
          fields: [:worker, :args],
          keys: [:target_session_id],
          period: :infinity,
          states: [:available, :scheduled, :executing, :retryable]
        ]
      )

    with {:ok, job} <- Oban.insert(changeset),
         {:ok, session} <- store_job_id(session, job.id) do
      {:ok, session}
    else
      {:error, reason} ->
        {:error, append_failed(:job_ensure_failed, %{"reason" => safe_reason(reason)})}
    end
  end

  defp store_job_id(%TargetSession{} = session, job_id) do
    session
    |> TargetSession.changeset(%{oban_job_id: job_id})
    |> Repo.update()
  end

  defp safe_reason(%Ecto.Changeset{}), do: "changeset"
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason), do: inspect(reason, limit: 5, printable_limit: 120)

  defp append_failed(code, details) do
    %AppendFailed{
      code: code,
      message: "could not ensure TargetSession job",
      details: details
    }
  end
end
