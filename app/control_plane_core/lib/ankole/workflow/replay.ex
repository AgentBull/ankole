defmodule Ankole.Workflow.Replay do
  @moduledoc "Commits deterministic program replay under its memo fence."
  import Ecto.Query, warn: false
  alias Ankole.Repo
  alias Ankole.Text
  alias Ankole.Workflow.Program
  alias Ankole.Workflow.ResultSchema
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  @memo_budget_bytes 6 * 1024 * 1024

  def commit_replay_pending(run_id, pending_calls, expected_memo_length)
      when is_integer(run_id) and run_id > 0 and is_list(pending_calls) and
             is_integer(expected_memo_length) and expected_memo_length >= 0 do
    Repo.transact(fn repo ->
      with :ok <- Ankole.Principals.WorkAccess.check_record_in_tx(repo, Run, run_id) do
        commit_replay_pending_in_tx(repo, run_id, pending_calls, expected_memo_length)
      end
    end)
  end

  def complete_replay(run_id, result_text, expected_memo_length)
      when is_integer(run_id) and run_id > 0 and is_binary(result_text) and
             is_integer(expected_memo_length) and expected_memo_length >= 0 do
    Repo.transact(fn repo ->
      case Ankole.Workflow.Slot.lock_run(repo, run_id) do
        %Run{status: :running} = run ->
          calls = Ankole.Workflow.Slot.lock_run_calls_by_sequence(repo, run.id)

          with :ok <- ensure_replay_snapshot(calls, expected_memo_length) do
            Ankole.Workflow.Lifecycle.conclude_run_in_tx(
              repo,
              run,
              :completed,
              result_text,
              %{},
              DateTime.utc_now()
            )
          end

        %Run{} = run ->
          {:ok, %{run: run, wakeup_event: nil}}

        nil ->
          {:error, :workflow_not_found}
      end
    end)
  end

  def fail_replay(run_id, code, summary, expected_memo_length)
      when is_integer(run_id) and run_id > 0 and is_binary(code) and is_binary(summary) and
             is_integer(expected_memo_length) and expected_memo_length >= 0 do
    Repo.transact(fn repo ->
      case Ankole.Workflow.Slot.lock_run(repo, run_id) do
        %Run{status: :running} = run ->
          calls = Ankole.Workflow.Slot.lock_run_calls_by_sequence(repo, run.id)

          with :ok <- ensure_replay_snapshot(calls, expected_memo_length) do
            error = %{
              "code" => Text.utf8_prefix(code, 128),
              "summary" => Text.utf8_prefix(summary, 2000)
            }

            Ankole.Workflow.Lifecycle.conclude_run_in_tx(
              repo,
              run,
              :failed,
              nil,
              error,
              DateTime.utc_now()
            )
          end

        %Run{} = run ->
          {:ok, %{run: run, wakeup_event: nil}}

        nil ->
          {:error, :workflow_not_found}
      end
    end)
  end

  defp commit_replay_pending_in_tx(repo, run_id, pending_calls, expected_memo_length) do
    case Ankole.Workflow.Slot.lock_run(repo, run_id) do
      %Run{status: :running} = run ->
        calls = Ankole.Workflow.Slot.lock_run_calls_by_sequence(repo, run.id)

        with :ok <- ensure_replay_snapshot(calls, expected_memo_length) do
          prepare_and_commit_pending(repo, run, calls, pending_calls)
        end

      %Run{} = run ->
        {:ok, %{run: run, new_calls: []}}

      nil ->
        {:error, :workflow_not_found}
    end
  end

  defp prepare_and_commit_pending(repo, run, calls, pending_calls) do
    prepared =
      with {:ok, %{new_calls: new_calls}} <-
             Program.stall_diff(calls, pending_calls, run.max_agent_calls) do
        prepare_new_calls(run, new_calls)
      end

    case prepared do
      {:ok, call_inputs, memo_bytes} ->
        with :ok <-
               (case call_inputs do
                  [] -> :ok
                  [_ | _] -> Ankole.Tenants.check_work_admission(Repo.tenant_id!())
                end),
             {:ok, calls, dispatch_events} <-
               insert_and_dispatch_calls(repo, run, call_inputs, DateTime.utc_now()),
             {:ok, run} <- Ankole.Workflow.Lifecycle.update_run_memo_bytes(repo, run, memo_bytes) do
          {:ok, %{run: run, new_calls: calls, dispatch_events: dispatch_events}}
        end

      {:error, reason} ->
        fail_pending_commit(repo, run, reason)
    end
  end

  defp ensure_replay_snapshot(calls, expected_memo_length) do
    {_memo, actual_memo_length} = Program.memo_prefix(calls)

    if actual_memo_length == expected_memo_length do
      :ok
    else
      {:error, :workflow_replay_snapshot_changed}
    end
  end

  defp prepare_new_calls(run, new_calls) do
    with true <-
           valid_reply_route?(run.reply_route || %{}) ||
             {:error, :workflow_reply_route_binding_missing} do
      Enum.reduce_while(new_calls, {:ok, [], run.memo_bytes}, fn new_call, {:ok, inputs, bytes} ->
        arguments = new_call.arguments

        with :ok <- validate_agent_arguments(arguments),
             {:ok, encoded} <- Torque.encode(arguments),
             total = bytes + byte_size(encoded),
             true <- total <= @memo_budget_bytes || {:error, :workflow_memo_budget_exceeded},
             attrs = call_attrs(run, new_call.call_seq, arguments),
             %Ash.Changeset{valid?: true} <-
               Ankole.Ash.for_create(AgentCall, :create_call, attrs) do
          {:cont, {:ok, [attrs | inputs], total}}
        else
          %Ash.Changeset{} = changeset ->
            {:halt,
             {:error, {:invalid_workflow_agent_call, Ankole.Ash.validation_details(changeset)}}}

          {:error, reason} ->
            {:halt, {:error, reason}}

          false ->
            {:halt, {:error, :workflow_memo_budget_exceeded}}
        end
      end)
      |> case do
        {:ok, inputs, bytes} -> {:ok, Enum.reverse(inputs), bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  def valid_reply_route?(route) do
    is_binary(route["binding_name"]) or match?({:ok, _}, Ecto.UUID.cast(route["conversation_id"]))
  end

  defp insert_and_dispatch_calls(repo, run, call_inputs, inserted_at) do
    created =
      Ankole.Ash.bulk_create(call_inputs, AgentCall, :create_call,
        transaction: false,
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        sorted?: true
      )

    case created do
      %Ash.BulkResult{status: :success, records: calls} ->
        sessions =
          Enum.map(calls, &{&1.agent_uid, Ankole.Workflow.Queries.task_session_id(&1.id)})

        :ok = Ankole.Sessions.Queue.lock_sessions_in_tx(repo, sessions)

        Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, events} ->
          case Ankole.Workflow.Mail.append_dispatch_event(repo, run, call, inserted_at) do
            {:ok, event} -> {:cont, {:ok, [event | events]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, events} -> {:ok, calls, Enum.reverse(events)}
          error -> error
        end

      %Ash.BulkResult{errors: errors} ->
        {:error, Ash.Error.to_error_class(errors)}
    end
  end

  defp fail_pending_commit(repo, run, reason) do
    {code, summary} = pending_failure(reason)
    error = %{"code" => code, "summary" => summary}

    with {:ok, result} <-
           Ankole.Workflow.Lifecycle.conclude_run_in_tx(
             repo,
             run,
             :failed,
             nil,
             error,
             DateTime.utc_now()
           ) do
      {:ok, result |> Map.put(:new_calls, [])}
    end
  end

  defp pending_failure({:workflow_replay_diverged, _details}) do
    {"workflow_replay_diverged",
     "Workflow replay no longer matches its durable Agent-call transcript."}
  end

  defp pending_failure({:workflow_agent_limit_exceeded, %{used: used, max: maximum}}) do
    {"workflow_agent_limit_exceeded",
     "Workflow replay requested #{used} Agent calls, above the run limit of #{maximum}. Reduce the fanout or split the "}
  end

  defp pending_failure(:workflow_memo_budget_exceeded) do
    {"workflow_memo_budget_exceeded",
     "Workflow memo data exceeded 6 MiB. Use fewer tasks, return summaries, or split the "}
  end

  defp pending_failure(reason) do
    {"workflow_agent_call_invalid",
     "Workflow replay produced an invalid Agent call: #{inspect(reason, limit: 10)}"}
  end

  defp validate_agent_arguments(arguments) do
    with prompt when is_binary(prompt) <- Map.get(arguments, "prompt"),
         true <- String.trim(prompt) != "" || {:error, :workflow_agent_prompt_required},
         :ok <- ResultSchema.validate_schema(Map.get(arguments, "schema", %{"type" => "string"})) do
      :ok
    else
      nil -> {:error, :workflow_agent_prompt_required}
      false -> {:error, :workflow_agent_prompt_required}
      {:error, _reason} = error -> error
      _value -> {:error, :workflow_agent_prompt_required}
    end
  end

  defp call_attrs(run, call_seq, arguments) do
    %{
      run_id: run.id,
      agent_uid: run.agent_uid,
      call_seq: call_seq,
      arguments: arguments,
      label: Ankole.Attrs.optional_text(arguments["label"]),
      model_profile: Ankole.Attrs.optional_text(arguments["model_profile"]),
      attempts: 0,
      error: %{}
    }
  end
end
