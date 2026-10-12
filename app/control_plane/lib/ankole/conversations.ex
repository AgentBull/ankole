defmodule Ankole.Conversations do
  @moduledoc "Wakes the single driver for committed conversation input. PostgreSQL owns the inbox."
  alias Ankole.Conversations.{Admission, Driver, Jobs.EnsureDriver}
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo

  def ensure_driver(key) do
    case Repo.get(Ankole.Principals.Principal, key.agent_uid) do
      %{type: :agent, tenant_id: tenant_id} -> ensure_in_tenant(key, tenant_id)
      _ -> {:error, :agent_not_found}
    end
  end

  defp ensure_in_tenant(key, tenant_id) do
    case Driver.whereis(key) do
      :undefined ->
        case DynamicSupervisor.start_child(
               Ankole.Conversations.Drivers,
               {Admission.driver(key), {key, tenant_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  def deliver(key, id) do
    with {:ok, pid} <- ensure_driver(key) do
      send(pid, {:inbox, id})
      :ok
    end
  end

  @spec deliver_events([ActorEvent.t() | nil]) :: :ok
  def deliver_events(events) do
    events = events |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)

    if Repo.in_transaction?() do
      Enum.each(events, fn event ->
        :ok =
          EnsureDriver.enqueue_in_tx(
            Repo,
            %{agent_uid: event.agent_uid, session_id: event.session_id},
            event.available_at
          )
      end)
    else
      Enum.each(events, &deliver_event/1)
    end

    :ok
  end

  @spec deliver_committed({:ok, term()} | {:error, term()}, (term() -> [ActorEvent.t() | nil])) ::
          term()
  def deliver_committed({:ok, value} = result, events) do
    deliver_events(events.(value))
    result
  end

  def deliver_committed(result, _events), do: result

  def stop_job_turn(job, turn) do
    if turn do
      Task.Supervisor.start_child(
        Ankole.Conversations.Tasks,
        Repo.bind_tenant(fn ->
          Ankole.SignalsGateway.ActorRuntime.TurnControl.dispatch([
            %{turn_ref: turn, verb: :stop, reason: nil, payload: %{}}
          ])
        end)
      )
    end

    job_turn(job)
    :ok
  end

  def job_turn(job) do
    case Driver.whereis(%{
           agent_uid: job.agent_uid,
           session_id: Ankole.BackgroundAgentJobs.job_session_id(job.id)
         }) do
      :undefined ->
        :ok

      pid ->
        send(pid, {:job_turn, job.id, job.attempts})
        :ok
    end
  end

  defp deliver_event(%{completed_at: nil, input_state: "open"} = event) do
    key = %{agent_uid: event.agent_uid, session_id: event.session_id}

    if DateTime.compare(event.available_at, DateTime.utc_now(:microsecond)) != :gt,
      do: deliver(key, event.id),
      else: EnsureDriver.enqueue(key, event.available_at)
  end

  defp deliver_event(_event), do: :ok
end
