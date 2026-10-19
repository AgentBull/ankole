defmodule Ankole.Sessions.Admission do
  @moduledoc "Admits durable input without reserving an Agent Computer."

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.Sessions.Commands
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Notices
  alias Ankole.Sessions.Run
  alias Ankole.Principals.Principal
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Sessions.Workspaces
  alias Ankole.Sessions.TurnRuntimeEnv
  alias Ankole.Sessions.SessionWorkspace
  alias Ankole.Workflow

  def driver(%{session_id: key}) do
    case Ankole.Sessions.Key.parse(key) do
      {:job, _} -> Ankole.Sessions.JobDriver
      _ -> Ankole.Sessions.Driver
    end
  end

  def driver(_key), do: Ankole.Sessions.Driver

  @spec admit(map(), Signal.t(), keyword()) :: {:ok, Run.t() | map()} | {:error, term()}
  def admit(key, event, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    attributes =
      event
      |> Ankole.Observability.signal_attributes()
      |> Map.put(
        "ankole.queue.age_ms",
        max(DateTime.diff(now, event.inserted_at, :millisecond), 0)
      )
      |> Map.put(
        "ankole.queue.ready_ms",
        max(DateTime.diff(now, event.available_at, :millisecond), 0)
      )

    Ankole.Observability.stage("session.admission.observed_committed", attributes, fn ->
      do_admit(key, event, Keyword.put(opts, :now, now))
    end)
  end

  defp do_admit(key, event, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    cond do
      not Signal.produced_by_kernel?(event) and
          Run.kind(key.session_id) in [:job, :workflow_task] ->
        reject_private_work_input(event, now)

      Run.kind(key.session_id) == :job ->
        Ankole.Sessions.CodexJob.admit(key, event, opts)

      true ->
        with {:ok, event} <- Run.type(event).prepare_input(event, now),
             {:ok, plan} <- Run.type(event).plan(event, opts) do
          attributes = Ankole.Observability.signal_attributes(event)

          prepared =
            Ankole.Observability.stage("session.admission.prepare", attributes, fn ->
              with :ok <- TokenQuota.ensure_available(key.agent_uid),
                   do: Context.runtime(key, plan.opts)
            end)

          Ankole.Observability.stage("session.admission.claim", attributes, fn ->
            Repo.transact(fn repo -> admit_in_tx(repo, key, event, plan, prepared, now) end)
          end)
        else
          {:closed, result} -> {:ok, result}
          error -> error
        end
        |> defer_workflow(event, now)
        |> Notices.finalize(event, now)
        |> Run.after_finalization()
    end
  end

  @doc false
  def reject_private_work_input(event, now) do
    Repo.transact(fn repo ->
      with {:ok, event} <-
             Queue.mark_event_dead_letter_in_tx(repo, event, now, %{
               "code" => "invalid_signal_target"
             }),
           do: {:ok, %{status: :dead_letter, signal: event}}
    end)
  end

  @spec authorize_event(Signal.t()) :: {:ok, Signal.t()} | {:error, term()}
  def authorize_event(event) do
    Repo.transact(fn repo -> authorize_event_in_tx(repo, event) end)
    |> case do
      {:ok, %{signal: completed} = result} ->
        Run.after_finalization({:ok, result})
        {:ok, completed}

      {:ok, %Signal{} = current} = result ->
        if current.input_state != "open" or not is_nil(current.completed_at),
          do: Run.after_finalization({:ok, %{signal: current}})

        result

      error ->
        error
    end
  end

  @spec authorize_event_in_tx(module(), Signal.t()) ::
          {:ok, Signal.t() | map()} | {:error, term()}
  def authorize_event_in_tx(_repo, %Signal{last_attempt_at: %DateTime{}} = event),
    do: {:ok, event}

  def authorize_event_in_tx(repo, event) do
    case authorize_new_in_tx(repo, event) do
      :ok ->
        {:ok, event}

      {:error, :tenant_suspended} ->
        Notices.reject_suspended_input_in_tx(repo, event, DateTime.utc_now(:microsecond))

      {:error, reason} ->
        Queue.mark_event_dead_letter_in_tx(
          repo,
          event,
          DateTime.utc_now(:microsecond),
          %{"code" => to_string(reason)}
        )
    end
  end

  defp defer_workflow({:error, :workflow_agent_at_capacity}, event, now) do
    with {:ok, event} <- Workflow.defer_task_event(event, DateTime.add(now, 30), :agent_capacity),
         do: {:ok, %{status: :deferred, signal: event}}
  end

  defp defer_workflow(result, _event, _now), do: result

  defp admit_in_tx(repo, key, snapshot, plan, prepared, now) do
    with {:ok, _} <- Workspaces.ensure_in_tx(repo, key.agent_uid, key.session_id),
         %SessionWorkspace{} = workspace <- Fence.lock_workspace_in_tx(repo, key),
         %Signal{agent_uid: uid, session_id: session} =
           event <-
           Ankole.Signals.lock_signal_in_tx(repo, snapshot.id),
         true <- uid == key.agent_uid and session == key.session_id,
         {:ok, :not_committed} <- finalize_workflow_input_in_tx(repo, event, plan),
         true <- is_nil(event.completed_at) and event.input_state == "open",
         :ok <- current_queue_head(repo, event),
         :ok <- authorize_attempt_in_tx(repo, event),
         :ok <- agent_active(repo, uid),
         {:ok, kind_context} <- Run.type(event).admit_in_tx(repo, event, plan),
         :ok <- Commands.prepare_new_in_tx(repo, event, now),
         {:ok, conversation} <-
           ModelHistory.ensure_and_lock_conversation_in_tx(repo, uid, session, event),
         {:ok, workspace} <-
           workspace |> Ecto.Changeset.change(epoch: workspace.epoch + 1) |> repo.update(),
         {:ok, event} <-
           event
           |> Signal.changeset(%{
             attempt_count: event.attempt_count + 1,
             last_attempt_at: now,
             data:
               if(plan.kind == :main,
                 do:
                   Ankole.Conversations.ModelPreferences.freeze_admission(
                     event,
                     Keyword.get(plan.opts, :profile, "primary")
                   ),
                 else: event.data
               )
           })
           |> repo.update() do
      run = %Run{
        agent_uid: uid,
        session_id: session,
        signal_id: event.id,
        epoch: workspace.epoch,
        event: event,
        conversation: conversation,
        workspace_id: workspace.id,
        kind: plan.kind
      }

      case prepared_spec(prepared, plan.kind) do
        {:ok, spec} ->
          finish_admission_in_tx(repo, %{run | spec: spec}, plan, kind_context, now)

        {:capacity, reason} ->
          with {:ok, event} <- Run.defer_retry_in_tx(repo, run, reason, now),
               do: {:ok, %{status: :deferred, signal: event}}

        error ->
          error
      end
    else
      {:ok, %{status: :completed} = result} -> {:ok, result}
      nil -> {:error, :input_unavailable}
      false -> {:error, :input_unavailable}
      {:error, :human_access_revoked} -> reject_access_in_tx(repo, snapshot, now)
      {:error, _} = error -> error
      _closed -> {:error, :input_unavailable}
    end
  end

  # The Driver may have read the queue before a Human reordered pending follow-ups.
  defp current_queue_head(
         _repo,
         %Signal{
           producer: :kernel,
           source: "conversation:" <> id,
           conversation_id: id,
           type: "conversation.message.addressed",
           last_attempt_at: nil
         } = event
       ) do
    case Queue.next_ready_event(event.agent_uid, event.session_id) do
      %Signal{id: id} when id == event.id -> :ok
      _ -> {:error, :input_unavailable}
    end
  end

  defp current_queue_head(_repo, _event), do: :ok

  defp finalize_workflow_input_in_tx(repo, event, %{kind: :workflow_task} = plan),
    do: Ankole.Sessions.WorkflowTask.finalize_input_in_tx(repo, event, plan)

  defp finalize_workflow_input_in_tx(_repo, _event, _plan), do: {:ok, :not_committed}

  defp fail_exhausted_workflow_in_tx(repo, event, %{kind: :workflow_task} = plan, reason),
    do: Ankole.Sessions.WorkflowTask.fail_exhausted_in_tx(repo, event, plan, reason)

  defp fail_exhausted_workflow_in_tx(_repo, _event, _plan, _reason), do: :ok

  defp prepared_spec({:error, {:model_profile_unavailable, _profile, reason}} = error, kind)
       when kind in [:main, :scheduled, :ambient] do
    if FailureDiagnostics.provider_capacity?(reason),
      do: {:capacity, reason},
      else: error
  end

  defp prepared_spec(prepared, _kind), do: prepared

  defp finish_admission_in_tx(repo, run, plan, kind_context, _now) do
    event = run.event
    delivered = event

    spec =
      run.spec
      |> Map.put(:workspace_id, run.workspace_id)
      |> Map.put(:runtime_env, TurnRuntimeEnv.resolve(event))
      |> Map.update!(:request_context, &Map.merge(&1, kind_context))

    run = %{run | delivered_event: delivered, spec: spec}

    if event.attempt_count - event.provider_capacity_attempt_count > 5 do
      reason = %{
        "code" => "conversation_attempts_exhausted",
        "attempt_count" => event.attempt_count
      }

      with :ok <- fail_exhausted_workflow_in_tx(repo, event, plan, reason),
           {:ok, result} <- Run.finalize_recovered_in_tx(repo, run, :dead_letter, reason) do
        {:ok, %{result | status: :dead_letter}}
      end
    else
      {:ok, run}
    end
  end

  # Tenant suspension permits recovery of accepted input. Each new admission
  # still checks the Human authorization; the current attempt keeps its rights.
  defp authorize_attempt_in_tx(repo, %Signal{last_attempt_at: %DateTime{}} = event),
    do: WorkAccess.check_in_tx(repo, event)

  defp authorize_attempt_in_tx(repo, event), do: authorize_new_in_tx(repo, event)

  defp authorize_new_in_tx(repo, %Signal{producer: :kernel, type: "command.stop"} = event),
    do: WorkAccess.check_in_tx(repo, event)

  defp authorize_new_in_tx(repo, event) do
    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         do: WorkAccess.check_in_tx(repo, event)
  end

  defp reject_access_in_tx(repo, snapshot, _now) do
    with {:ok, result} <-
           Run.reject_input_in_tx(repo, snapshot, :dead_letter, :human_access_revoked),
         do: {:ok, Map.put(result, :status, :access_revoked)}
  end

  defp agent_active(repo, uid) do
    case repo.get(Principal, uid) do
      %Principal{type: :agent, status: :active} -> :ok
      _inactive -> {:error, :agent_not_active}
    end
  end
end
