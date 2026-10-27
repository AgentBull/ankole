defmodule Ankole.Workflow.TaskLifecycle do
  @moduledoc """
  Owns task admission and state transitions.

  Each `_in_tx` function runs in the transaction of its caller. Sessions and
  Background Agent Jobs call them in their own transactions. The caller does
  the post-commit work with `Ankole.Workflow.cleanup_terminal_transition/1`.
  """
  alias Ankole.Repo
  alias Ankole.Text
  alias Ankole.Workflow.ResultSchema
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  @memo_budget_bytes 6 * 1024 * 1024
  @value_max_bytes 24 * 1024
  @max_wake_count 16
  @min_wake_after_ms 60000
  @max_wake_after_ms 172_800_000

  def compensate_turn_error_in_tx(
        %{agent_uid: agent_uid, session_id: session_id},
        reason,
        %DateTime{} = now
      )
      when is_binary(agent_uid) and is_binary(session_id) and is_map(reason) do
    case Ankole.Workflow.Queries.parse_task_session_id(session_id) do
      {:ok, call_id} -> compensate_call_in_tx(call_id, agent_uid, reason, now)
      :error -> {:ok, nil}
    end
  end

  def compensate_turn_error_in_tx(_event, _reason, %DateTime{}) do
    {:ok, nil}
  end

  def authorize_delegated_job_owner_in_tx(agent_uid, owner_session_id)
      when is_binary(agent_uid) and is_binary(owner_session_id) do
    case Ankole.Workflow.Queries.parse_task_session_id(owner_session_id) do
      {:ok, call_id} -> authorize_delegated_job_in_tx(call_id, agent_uid)
      :error -> :ok
    end
  end

  def lock_task_progress_in_tx(call_id, agent_uid, session_id, attempt)
      when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and is_binary(session_id) and
             is_integer(attempt) and attempt > 0 do
    with :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid),
         :ok <- authorize_session(call, session_id) do
      current =
        if run.status == :running and call.status == :running and call.attempts == attempt do
          call
        end

      {:ok, current}
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  def touch_running_task_in_tx(nil, _now) do
    :ok
  end

  def touch_running_task_in_tx(%AgentCall{status: :running} = call, now) do
    case Ankole.Ash.update(call, :update_metadata, %{progress_at: now}) do
      {:ok, _call} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def claim_task_in_tx(call_id, agent_uid, max_running_per_agent, opts \\ [])
      when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) and
             is_integer(max_running_per_agent) and max_running_per_agent > 0 do
    with {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = snapshot_run <- Ankole.Workflow.Slot.get_run(run_id, agent_uid),
         %AgentCall{} = snapshot_call <- Ankole.Workflow.Slot.get_call(call_id, run_id, agent_uid),
         :ok <- ensure_claimable_or_adopted(snapshot_run, snapshot_call, opts),
         :ok <-
           (if snapshot_call.status == :running do
              :ok
            else
              with :ok <- Ankole.Tenants.check_work_admission_in_tx(Repo.tenant_id!()) do
                Ankole.Principals.WorkAccess.check_in_tx(snapshot_run)
              end
            end),
         :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid),
         :ok <- ensure_claimable_or_adopted(run, call, opts) do
      if call.status == :running do
        {:ok, %{call: call, run: run}}
      else
        with :ok <- Ankole.Workflow.Slot.enforce_capacity(run, max_running_per_agent),
             {:ok, call} <-
               Ankole.Ash.update(call, :claim, %{
                 attempts: call.attempts + 1,
                 attention: false,
                 error: %{},
                 wake_kind: nil,
                 wake_at: nil,
                 progress_at: DateTime.utc_now()
               }) do
          {:ok, %{call: call, run: run}}
        end
      end
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_claimable_or_adopted(%Run{status: :running}, %AgentCall{status: :running}, opts) do
    if Keyword.get(opts, :adopt_running, false) do
      :ok
    else
      {:error, {:workflow_task_not_queued, :running}}
    end
  end

  defp ensure_claimable_or_adopted(run, call, _opts) do
    ensure_claimable(run, call)
  end

  defp authorize_delegated_job_in_tx(call_id, agent_uid)
       when is_integer(call_id) and call_id > 0 and is_binary(agent_uid) do
    with :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid),
         :ok <- ensure_delegated_job_owner_running(run, call) do
      :ok
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  def submit_result_in_tx(call_id, agent_uid, session_id, outcome) do
    with :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid),
         :ok <- authorize_session(call, session_id) do
      submit_locked(run, call, outcome, DateTime.utc_now())
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  def sleep_task_in_tx(call_id, agent_uid, session_id, params) do
    with {:ok, wake_after_ms} <- validate_wake_after(Map.get(params, :wake_after_ms)),
         {:ok, note} <- validate_sleep_note(Map.get(params, :note)),
         :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid),
         :ok <- authorize_session(call, session_id) do
      sleep_locked(run, call, wake_after_ms, note, Map.get(params, :attention) == true)
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  def fail_unstarted_task_in_tx(call_id, agent_uid, code, summary, available_at) do
    with {:ok, {run, call}} <- lock_task_in_tx(call_id, agent_uid) do
      fail_unstarted_task_locked(run, call, task_failure(code, summary), available_at)
    end
  end

  def model_unavailable_in_tx(call_id, agent_uid, session_id, profile, reason, available_at) do
    with {:ok, {run, call}} <- lock_task_in_tx(call_id, agent_uid),
         :ok <- authorize_session(call, session_id) do
      failure =
        task_failure(
          "workflow_task_model_profile_unavailable",
          "Model profile #{profile} is unavailable: #{inspect(reason)}"
        )

      if call.status == :running do
        submit_locked(run, call, Map.put(failure, "ok", false), available_at)
      else
        fail_unstarted_task_locked(run, call, failure, available_at)
      end
    end
  end

  def lock_task_in_tx(call_id, agent_uid) do
    with :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid) do
      {:ok, {run, call}}
    else
      nil -> {:error, :workflow_task_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp task_failure(code, summary) do
    %{
      "code" => Text.utf8_prefix(code, 128),
      "summary" => Text.utf8_prefix(summary, 2000),
      "retryable" => false
    }
  end

  defp fail_unstarted_task_locked(run, call, failure, available_at) do
    cond do
      run.status != :running ->
        {:ok, %{accepted: false, call: call, run: run}}

      call.status in [:queued, :sleeping] ->
        commit_failure(run, call, failure, false, available_at)

      call.status in AgentCall.terminal_statuses() ->
        {:ok, %{accepted: false, call: call, run: run}}

      true ->
        {:error, {:workflow_task_not_queued, call.status}}
    end
  end

  defp sleep_locked(%Run{status: status} = run, call, _wake_after_ms, _note, _attention?)
       when status != :running do
    with {:ok, call} <- cancel_stopped_run_call(call, DateTime.utc_now()),
         do: {:ok, %{call: call, run: run}}
  end

  defp sleep_locked(%Run{}, %AgentCall{status: status}, _wake_after_ms, _note, _attention?)
       when status != :running do
    {:error, {:workflow_task_not_running, status}}
  end

  defp sleep_locked(
         %Run{},
         %AgentCall{wake_count: wake_count},
         _wake_after_ms,
         _note,
         _attention?
       )
       when wake_count >= @max_wake_count do
    {:error, :workflow_task_wake_budget_exhausted}
  end

  defp sleep_locked(run, call, wake_after_ms, note, attention?) do
    now = DateTime.utc_now()

    with :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx([
             {call.agent_uid, Ankole.Workflow.Queries.task_session_id(call.id)},
             {run.agent_uid, run.owner_session_id}
           ]),
         {:ok, call} <-
           Ankole.Ash.update(call, :sleep, %{
             wake_kind: :sleep,
             attempts: 0,
             sleep_note: note,
             wake_at: DateTime.add(now, wake_after_ms, :millisecond),
             wake_count: call.wake_count + 1,
             attention: attention?,
             error: %{}
           }),
         {:ok, _wake_event} <- Ankole.Workflow.Mail.append_wake_event(run, call, now),
         {:ok, attention_event} <-
           Ankole.Workflow.Mail.maybe_append_attention_event(run, call, attention?, now) do
      {:ok, %{call: call, run: run, attention_event: attention_event, released_slot?: true}}
    end
  end

  defp validate_wake_after(value)
       when is_integer(value) and value >= @min_wake_after_ms and value <= @max_wake_after_ms do
    {:ok, value}
  end

  defp validate_wake_after(_value) do
    {:error, :invalid_workflow_wake_after}
  end

  defp validate_sleep_note(value) when is_binary(value) do
    note = String.trim(value)

    if note != "" and String.length(note) <= 200 do
      {:ok, note}
    else
      {:error, :invalid_workflow_sleep_note}
    end
  end

  defp validate_sleep_note(_value) do
    {:error, :invalid_workflow_sleep_note}
  end

  defp compensate_call_in_tx(call_id, agent_uid, reason, now) do
    with :ok <- Ankole.Workflow.Slot.lock_agent_slots(agent_uid),
         {:ok, run_id} <- Ankole.Workflow.Slot.call_run_id(call_id, agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(run_id, agent_uid),
         %AgentCall{} = call <- Ankole.Workflow.Slot.lock_call(call_id, run.id, agent_uid) do
      cond do
        run.status != :running and call.status == :running ->
          with {:ok, call} <- cancel_stopped_run_call(call, now) do
            {:ok, %{accepted: false, call: call, run: run}}
          end

        run.status != :running or call.status != :running ->
          {:ok, nil}

        true ->
          failure = failure_from_reason(reason)
          commit_failure(run, call, failure, call.attempts < 3, now)
      end
    else
      nil -> {:ok, nil}
      {:error, :workflow_task_not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp cancel_stopped_run_call(%AgentCall{status: :running} = call, now) do
    with {:ok, call} <- Ankole.Ash.update(call, :cancel, %{result: nil, error: %{}}),
         :ok <- notify_task_ready(call, now),
         do: {:ok, call}
  end

  defp cancel_stopped_run_call(call, _now), do: {:ok, call}

  defp submit_locked(
         %Run{status: :cancelled, error: %{"code" => "human_access_revoked"}} = run,
         %AgentCall{status: :running} = call,
         outcome,
         now
       ) do
    if outcome["ok"] == true do
      commit_success(run, call, outcome["value"], now)
    else
      with {:ok, failure} <- validate_failure(outcome) do
        commit_failure(run, call, failure, false, now)
      end
    end
  end

  defp submit_locked(%Run{status: status} = run, call, _outcome, now)
       when status != :running do
    with {:ok, call} <- cancel_stopped_run_call(call, now),
         do: {:ok, %{accepted: false, call: call, run: run}}
  end

  defp submit_locked(%Run{}, %AgentCall{status: status}, _outcome, _now)
       when status != :running do
    {:error, {:workflow_task_not_running, status}}
  end

  defp submit_locked(run, call, outcome, now) do
    if outcome["ok"] == true do
      commit_success(run, call, outcome["value"], now)
    else
      with {:ok, failure} <- validate_failure(outcome) do
        commit_failure(run, call, failure, failure["retryable"] and call.attempts < 3, now)
      end
    end
  end

  defp commit_success(_run, _call, nil, _now) do
    {:error, :workflow_result_null}
  end

  defp commit_success(run, call, value, now) do
    schema = Map.get(call.arguments, "schema", %{"type" => "string"})

    with {:ok, encoded} <- Torque.encode(value),
         :ok <- ensure_result_value_size(encoded),
         {:ok, value} <- ResultSchema.validate(schema, value),
         envelope = %{"ok" => true, "value" => value},
         {:ok, envelope_encoded} <- Torque.encode(envelope),
         memo_bytes = run.memo_bytes + byte_size(envelope_encoded) do
      if memo_bytes > @memo_budget_bytes do
        fail_memo_budget(run, call, now)
      else
        with {:ok, call} <- Ankole.Ash.update(call, :complete, %{result: envelope, error: %{}}),
             {:ok, run} <- Ankole.Workflow.Lifecycle.update_run_memo_bytes(run, memo_bytes),
             :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue(run.id),
             :ok <- notify_task_ready(call, now) do
          {:ok, %{accepted: true, call: call, run: run, released_slot?: true}}
        end
      end
    end
  end

  def commit_failure(run, call, failure, true, available_at) do
    with {:ok, call} <-
           Ankole.Ash.update(call, :requeue_stale, %{
             wake_kind: nil,
             wake_at: nil,
             result: nil,
             error: Map.delete(failure, "retryable")
           }),
         :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue(run.id),
         :ok <- notify_task_ready(call, available_at) do
      {:ok, %{accepted: true, call: call, run: run, released_slot?: true}}
    end
  end

  def commit_failure(run, call, failure, false, now) do
    released_slot? = call.status == :running
    envelope = failure |> Map.delete("retryable") |> Map.put("ok", false)

    with {:ok, envelope_encoded} <- Torque.encode(envelope),
         memo_bytes = run.memo_bytes + byte_size(envelope_encoded) do
      if memo_bytes > @memo_budget_bytes do
        fail_memo_budget(run, call, now)
      else
        with {:ok, call} <-
               Ankole.Ash.update(call, :fail, %{
                 wake_kind: nil,
                 wake_at: nil,
                 result: envelope,
                 error: Map.delete(envelope, "ok")
               }),
             {:ok, run} <- Ankole.Workflow.Lifecycle.update_run_memo_bytes(run, memo_bytes),
             :ok <- Ankole.Workflow.Jobs.PokeRun.enqueue(run.id),
             :ok <- notify_task_ready(call, now) do
          {:ok, %{accepted: true, call: call, run: run, released_slot?: released_slot?}}
        end
      end
    end
  end

  defp fail_memo_budget(run, call, now) do
    error = %{
      "code" => "workflow_memo_budget_exceeded",
      "summary" =>
        "Workflow memo data exceeded 6 MiB. Use fewer tasks, return summaries, or split the work into more runs."
    }

    with {:ok, call} <- Ankole.Ash.update(call, :fail, %{result: nil, error: error}),
         {:ok, terminal} <-
           Ankole.Workflow.Lifecycle.conclude_run_in_tx(run, :failed, nil, error, now),
         :ok <- notify_task_ready(call, now) do
      {:ok, terminal |> Map.merge(%{accepted: true, call: call})}
    end
  end

  def notify_task_ready(call, available_at) do
    Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
      %{agent_uid: call.agent_uid, session_id: Ankole.Workflow.Queries.task_session_id(call.id)},
      available_at
    )
  end

  defp ensure_claimable(%Run{status: :running}, %AgentCall{status: status})
       when status in [:queued, :sleeping] do
    :ok
  end

  defp ensure_claimable(%Run{status: status}, _call) when status != :running do
    {:error, {:workflow_run_terminal, status}}
  end

  defp ensure_claimable(_run, %AgentCall{status: status}) do
    {:error, {:workflow_task_not_queued, status}}
  end

  defp ensure_delegated_job_owner_running(
         %Run{status: :running},
         %AgentCall{status: :running}
       ) do
    :ok
  end

  defp ensure_delegated_job_owner_running(%Run{status: status}, _call) when status != :running do
    {:error, {:workflow_run_terminal, status}}
  end

  defp ensure_delegated_job_owner_running(_run, %AgentCall{status: status}) do
    {:error, {:workflow_task_not_running, status}}
  end

  defp authorize_session(call, session_id) do
    if session_id == Ankole.Workflow.Queries.task_session_id(call.id) do
      :ok
    else
      {:error, :workflow_task_session_mismatch}
    end
  end

  defp ensure_result_value_size(encoded) when byte_size(encoded) <= @value_max_bytes do
    :ok
  end

  defp ensure_result_value_size(_encoded) do
    {:error, :workflow_result_too_large}
  end

  defp validate_failure(outcome) do
    code = Ankole.Attrs.optional_text(outcome["code"])
    summary = Ankole.Attrs.optional_text(outcome["summary"])

    cond do
      is_nil(code) ->
        {:error, :workflow_failure_code_required}

      byte_size(code) > 128 ->
        {:error, :workflow_failure_code_too_large}

      is_nil(summary) ->
        {:error, :workflow_failure_summary_required}

      byte_size(summary) > 2000 ->
        {:error, :workflow_failure_summary_too_large}

      true ->
        {:ok,
         %{
           "code" => code,
           "summary" => summary,
           "retryable" => outcome["retryable"] == true
         }}
    end
  end

  defp failure_from_reason(reason) do
    code =
      Ankole.Attrs.optional_text(reason["code"]) || "workflow_task_turn_failed"

    summary =
      Ankole.Attrs.optional_text(reason["message"]) ||
        Ankole.Attrs.optional_text(reason["summary"]) ||
        "The Workflow task Turn failed before it submitted a result."

    %{
      "code" => Text.utf8_prefix(code, 128),
      "summary" => Text.utf8_prefix(summary, 2000),
      "retryable" => true
    }
  end
end
