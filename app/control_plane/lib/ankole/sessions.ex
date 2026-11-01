defmodule Ankole.Sessions do
  @moduledoc """
  Wakes the single driver for committed Session input. PostgreSQL owns the inbox.

  This module is the Sessions domain. Each top-level Session operation runs its
  `*_in_tx` function inside `Ankole.Repo.transact_top_level/2`.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Jobs.EnsureDriver
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      route(
        Ankole.Sessions.ConsoleOperations,
        :get,
        "/agents/:agent_uid/sessions",
        :console_sessions,
        name: "list_agent_sessions"
      )

      route(
        Ankole.Sessions.ConsoleOperations,
        :get,
        "/conversations/:conversation_id/standing-orders",
        :console_standing_orders,
        name: "get_conversation_standing_orders"
      )

      route(
        Ankole.Sessions.ConsoleOperations,
        :put,
        "/conversations/:conversation_id/standing-orders",
        :console_put_standing_orders,
        name: "put_conversation_standing_orders"
      )
    end
  end

  resources do
    resource(Ankole.Sessions.ConsoleOperations)
    resource(Ankole.Sessions.SessionWorkspace)
    resource(Ankole.Sessions.RoundState)
    resource(Ankole.Sessions.Receipt)
    resource(Ankole.Sessions.AmbientJudgment)
  end

  @doc "Returns the durable input identities included in one model request."
  def response_signal_ids(%{response_id: "resp_" <> id, metadata: metadata}) do
    steers = Ankole.Sessions.RoundState.get(%{id: id}).steer_event_ids
    Enum.uniq(Enum.reject([metadata["signal_id"] | steers], &is_nil/1))
  end

  @doc "Returns the current work state from the durable Session queue."
  def status(%{agent_uid: uid, session_id: session}) do
    statuses([{uid, session}])[{uid, session}]
  end

  @doc "Returns public work states for the requested execution Sessions."
  def statuses(keys) do
    now = DateTime.utc_now(:microsecond)
    events = Ankole.Signals.session_status_signals(Enum.uniq(keys), now)
    by_session = Map.new(events, &{{&1.agent_uid, &1.session_id}, &1})
    Map.new(keys, &{&1, status_from_event(by_session[&1], now)})
  end

  defp status_from_event(event, now) do
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
  def driver_name(key, tenant_id \\ Ankole.Repo.tenant_id!()),
    do: {Ankole.Sessions.Driver, tenant_id, key.agent_uid, key.session_id}

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
    case Ankole.Principals.get_principal(key.agent_uid) do
      {:ok, %{type: :agent, tenant_id: tenant_id}} -> ensure_in_tenant(key, tenant_id)
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
    Repo.assert_outside_transaction!()

    with {:ok, _pid} <- ensure_driver(key) do
      Ankole.Sessions.Events.publish_input(key.agent_uid, key.session_id, id)
    end
  end

  @spec deliver_events([Signal.t() | nil]) :: :ok
  def deliver_events(events) do
    events = events |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)

    if Repo.in_transaction?() do
      Enum.each(events, fn event ->
        :ok =
          EnsureDriver.enqueue_in_tx(
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

  defp deliver_event(%{status: live_status} = event) when live_status in [:queued, :running] do
    key = %{agent_uid: event.agent_uid, session_id: event.session_id}

    if DateTime.compare(event.available_at, DateTime.utc_now(:microsecond)) != :gt,
      do: deliver(key, event.id),
      else: EnsureDriver.enqueue(key, event.available_at)
  end

  defp deliver_event(_event), do: :ok
end
