defmodule Ankole.Sessions do
  @moduledoc "Wakes the single driver for committed Session input. PostgreSQL owns the inbox."
  import Ecto.Query
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Jobs.EnsureDriver
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  @doc "Returns the durable input identities included in one model request."
  def response_signal_ids(%{response_id: "resp_" <> id, metadata: metadata}) do
    steers = Ankole.Sessions.RoundState.get(%{id: id}).steer_event_ids
    Enum.uniq(Enum.reject([metadata["signal_id"] | steers], &is_nil/1))
  end

  @doc "Returns the current work state from the durable Session queue."
  def status(%{agent_uid: uid, session_id: session}) do
    now = DateTime.utc_now(:microsecond)

    event =
      Repo.one(
        from(event in Signal,
          where:
            event.agent_uid == ^uid and event.session_id == ^session and
              event.input_state == "open" and is_nil(event.completed_at),
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? > ? THEN 2 WHEN ? IS NULL THEN 1 ELSE 0 END",
                event.available_at,
                ^now,
                event.last_attempt_at
              ),
            asc: event.available_at,
            asc: event.queue_sequence
          ],
          limit: 1
        )
      )

    case event do
      nil ->
        %{state: :idle, retry_at: nil}

      %Signal{last_attempt_at: nil} ->
        %{state: :queued, retry_at: nil}

      %Signal{available_at: due} ->
        if DateTime.compare(due, now) == :gt,
          do: %{state: :retrying, retry_at: due},
          else: %{state: :running, retry_at: nil}
    end
  end

  @doc "The shared registry identity for ordinary and background Job drivers."
  def driver_name(key), do: {Ankole.Sessions.Driver, key.agent_uid, key.session_id}

  @doc "Finds the existing driver without starting it."
  def driver_pid(key), do: :global.whereis_name(driver_name(key))

  @doc "Returns the active model history identity without creating history."
  def active_model_conversation_id(key) do
    case Ankole.Sessions.ModelHistory.active_conversation(key.agent_uid, key.session_id) do
      %{id: id} -> id
      nil -> nil
    end
  end

  def ensure_driver(key) do
    case Repo.get(Ankole.Principals.Principal, key.agent_uid) do
      %{type: :agent, tenant_id: tenant_id} -> ensure_in_tenant(key, tenant_id)
      _ -> {:error, :agent_not_found}
    end
  end

  defp ensure_in_tenant(key, tenant_id) do
    case Ankole.Sessions.driver_pid(key) do
      :undefined ->
        case DynamicSupervisor.start_child(
               Ankole.Sessions.Drivers,
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

  @spec deliver_events([Signal.t() | nil]) :: :ok
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

  def stop_job_turn(job, turn) do
    if turn do
      Task.Supervisor.start_child(
        Ankole.Sessions.Tasks,
        Repo.bind_tenant(fn ->
          Ankole.Sessions.TurnControl.dispatch([
            %{turn_ref: turn, verb: :stop, reason: nil, payload: %{}}
          ])
        end)
      )
    end

    job_turn(job)
    :ok
  end

  def job_turn(job) do
    case Ankole.Sessions.driver_pid(%{
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
