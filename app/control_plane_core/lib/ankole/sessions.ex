defmodule Ankole.Sessions do
  @moduledoc """
  Wakes the single driver for committed Session input. PostgreSQL owns the inbox.

  This module is the Sessions domain. Each Session operation is a generic
  action of `Ankole.Sessions.SessionWorkspace` (declared in
  `Ankole.Sessions.Operations`) that owns its transaction. A define gives the
  Ash error class; the calling module gives back the domain reason with
  `Ankole.Errors.reason/1`.
  """
  use Ankole.Ash.Domain

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Jobs.EnsureDriver
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  resources do
    resource Ankole.Sessions.SessionWorkspace do
      define(:get_session_workspace, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_session_workspaces, action: :read)
      define(:admit_input, args: [:key, :snapshot, :plan, :prepared, :now])
      define(:dead_letter_input, args: [:event, :now, :reason])
      define(:authorize_input, args: [:event])
      define(:admit_job_input, args: [:admission, :snapshot])
      define(:check_job_turn, args: [:run])
      define(:claim_job_mailbox, args: [:run])
      define(:abort_job_turn, args: [:ref, :worker_id, :error, :now])
      define(:reject_job_admission, args: [:job, :event, :code, :reason, :now])
      define(:defer_run_retry, args: [:run, :error, :now])
      define(:record_run_round, args: [:run])
      define(:inject_run_input, args: [:run, :events, :now])
      define(:finalize_run, args: [:run, :outcome, :reason, :images])
      define(:refund_run, args: [:run, :mode])
      define(:check_run, args: [:run, :lock])
      define(:reclaim_run, args: [:run])
      define(:apply_command, args: [:key, :event, :now])
      define(:resolve_retry_action, args: [:run, :event])
      define(:retry_current_turn, args: [:run, :event, :now])
      define(:post_stopped_notice, args: [:event, :command_type])
      define(:submit_workflow_failure, args: [:run, :failure])
      define(:compensate_workflow_error, args: [:run, :error])
      define(:consume_compress_command, args: [:input, :compaction, :now])
      define(:consume_command_feedback, args: [:input, :text, :now])
      define(:fail_workflow_model, args: [:event, :profile, :reason, :now])
      define(:reject_suspended_input, args: [:event, :now])
      define(:complete_without_turn, args: [:signal, :status, :fields, :commit_notice])
      define(:apply_revision, args: [:run, :event, :now])
      define(:process_message_removal, args: [:input, :now])
      define(:resolve_ambient, args: [:event, :now])
      define(:retry_ambient_triage, args: [:key, :event, :now])
      define(:record_ambient_judgment, args: [:key, :signal_id, :route, :attrs])
      define(:set_standing_orders, args: [:agent_uid, :signal_id, :orders, :now])
      define(:execute_receipt, args: [:run, :response_id, :call_id, :operation])
      define(:link_run_input, args: [:run])
      define(:read_worker_status, args: [:run])
      define(:enqueue_session_resets, args: [:boundary_at, :opts])
      define(:reset_session, args: [:session_key, :input, :now])
      define(:close_workflow_input, args: [:event, :now])
    end

    resource Ankole.Sessions.RoundState do
      define(:get_round_state, action: :read, get_by: [:message_id], not_found_error?: false)
      define(:list_round_states, action: :read)
    end

    resource Ankole.Sessions.Receipt do
      define(:get_receipt,
        action: :read,
        get_by: [:response_id, :call_id],
        not_found_error?: false
      )

      define(:list_receipts, action: :read)
    end

    resource Ankole.Sessions.AmbientJudgment do
      define(:get_ambient_judgment, action: :read, get_by: [:signal_id], not_found_error?: false)
      define(:list_ambient_judgments, action: :read)
    end
  end

  @doc "Returns the durable input identities included in one model request."
  def response_signal_ids(%{response_id: "resp_" <> id, metadata: metadata}) do
    steers = Ankole.Sessions.RoundState.get(%{id: id}).steer_event_ids
    Enum.uniq(Enum.reject([metadata["signal_id"] | steers], &is_nil/1))
  end

  @doc "Returns the current work state from the durable Session queue."
  def status(%{agent_uid: uid, session_id: session}) do
    now = DateTime.utc_now(:microsecond)

    event = Ankole.Sessions.Queue.status_event(Repo, uid, session, now)

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

  defp deliver_event(%{status: live_status} = event) when live_status in [:queued, :running] do
    key = %{agent_uid: event.agent_uid, session_id: event.session_id}

    if DateTime.compare(event.available_at, DateTime.utc_now(:microsecond)) != :gt,
      do: deliver(key, event.id),
      else: EnsureDriver.enqueue(key, event.available_at)
  end

  defp deliver_event(_event), do: :ok
end
