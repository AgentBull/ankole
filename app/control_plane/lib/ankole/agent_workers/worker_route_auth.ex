defmodule Ankole.AgentWorkers.WorkerRouteAuth do
  @moduledoc "Accepts Worker RPC only for its bound Agent and current durable input or Job attempt."
  import Ecto.Query
  alias Ankole.{Repo, Principals.WorkAccess}
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.RunRef
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers

  def authorize_turn(ref, worker_id, effect) do
    case Repo.transact(fn repo -> authorize_turn_in_tx(repo, ref, worker_id, effect) end) do
      {:ok, :authorized} -> :ok
      error -> error
    end
  end

  def authorize_turn_in_tx(repo, ref, worker_id, effect, opts \\ [])

  def authorize_turn_in_tx(repo, ref, uid, effect, opts)
      when effect in [:read, :write, :terminal] do
    case ref do
      %JobTurnRef{} ->
        with :ok <- lock_job_write(repo, uid, effect),
             %Job{attempts: attempt, status: status} <-
               job(repo, ref, effect),
             true <- attempt == ref.attempt and (status == "running" or effect == :terminal),
             :ok <- input(repo, ref, status != "running", opts) do
          {:ok, :authorized}
        else
          {:error, _} = error -> error
          _ -> {:error, :background_agent_job_attempt_changed}
        end

      %RunRef{} ->
        with :ok <- input(repo, ref, false, opts), do: {:ok, :authorized}
    end
  end

  def authorize_turn_in_tx(_repo, _ref, _worker_id, _effect, _opts),
    do: {:error, :worker_not_assigned_to_turn}

  defp lock_job_write(_repo, _uid, :read), do: :ok

  defp lock_job_write(repo, uid, _effect) do
    AgentWorkers.lock_in_tx(repo, uid)
    Lifecycle.lock_agent_slots(repo, uid)
  end

  defp job(repo, ref, effect) do
    query = from j in Job, where: j.id == ^ref.job_id and j.agent_uid == ^ref.agent_uid
    query = if effect == :read, do: query, else: lock(query, "FOR UPDATE")
    repo.one(query)
  end

  defp admitted_access(_repo, %{last_attempt_at: %DateTime{}}), do: :ok
  defp admitted_access(repo, event), do: WorkAccess.check_in_tx(repo, event)

  defp input(repo, ref, terminal?, opts) do
    query =
      from e in Signal,
        where:
          e.id == ^ref.signal_id and e.agent_uid == ^ref.agent_uid and
            e.session_id == ^ref.session_id

    query = if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query

    case repo.one(query) do
      %Signal{} = event ->
        if terminal? or (event.input_state == "open" and is_nil(event.completed_at)),
          do: admitted_access(repo, event),
          else: {:error, :run_closed}

      nil ->
        {:error, :run_closed}
    end
  end
end
