defmodule Ankole.Conversations.Completion do
  alias Ankole.AIGateway.ToolResultJournal
  @moduledoc "Commits terminal input, domain outcomes and the visible reply under the Run fence."
  import Ecto.Query

  import Ankole.Conversations.Run,
    only: [restore_tape: 1, restore_tape: 2, call_id: 1, response_id: 1, type: 1]

  alias Ankole.AIGateway

  alias Ankole.Conversations.{
    Fence,
    Notices,
    Outcome,
    Presentation,
    Receipts,
    RoundState,
    Run,
    ToolResult
  }

  alias Ankole.Repo
  alias Ankole.SignalsGateway.{ActorEvent, Actors, AIGatewayLink}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace

  @spec finalize(Run.t(), Outcome.t(), term()) :: {:ok, map()} | {:error, term()}
  def finalize(run, outcome \\ :loop_finished, reason \\ nil) do
    Repo.transact(fn repo -> finalize_in_tx(repo, run, outcome, reason) end)
    |> after_finalization()
  end

  def after_finalization(result) do
    case result do
      {:ok, %{run: run} = result} ->
        if result.journal,
          do: ToolResultJournal.publish_tool_result_events(result.journal.message)

        Presentation.stop(run)
        {:ok, result}

      other ->
        other
    end
  end

  @spec finalize_recovered_in_tx(module(), Run.t(), Outcome.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def finalize_recovered_in_tx(repo, run, outcome, reason) do
    with :ok <- Fence.check_in_tx(repo, run),
         {:ok, _} <- end_model_in_tx(repo, run, :stopped, DateTime.utc_now(:microsecond)),
         {:ok, {_state, run}} <- restore_tape(run),
         do: finalize_in_tx(repo, run, outcome, reason)
  end

  @doc "Closes an admitted Workflow input whose terminating tool already committed."
  @spec finalize_committed_workflow_input_in_tx(module(), ActorEvent.t()) ::
          {:ok, :not_committed | map()} | {:error, term()}
  def finalize_committed_workflow_input_in_tx(repo, snapshot) do
    with %ActorSessionWorkspace{} = workspace <-
           repo.one(
             from w in ActorSessionWorkspace,
               where: w.agent_uid == ^snapshot.agent_uid and w.session_id == ^snapshot.session_id,
               lock: "FOR UPDATE"
           ),
         %ActorEvent{completed_at: nil, input_state: "open", last_attempt_at: %DateTime{}} =
           event <- Actors.lock_actor_event_in_tx(repo, snapshot.id),
         %{} = conversation <-
           AIGatewayLink.active_conversation_for_update(
             repo,
             event.agent_uid,
             event.session_id
           ),
         {:ok, {_state, run}} <-
           restore_tape(
             %Run{
               agent_uid: event.agent_uid,
               session_id: event.session_id,
               actor_event_id: event.id,
               epoch: workspace.epoch,
               event: event,
               delivered_event: event,
               kind: :workflow_task,
               conversation: conversation,
               workspace_id: workspace.id,
               spec: %{request_context: %{}}
             },
             false
           ),
         outcome when outcome in [:sleeping, :submitted] <- committed_workflow_outcome(run),
         {:ok, workspace} <-
           workspace |> Ecto.Changeset.change(epoch: workspace.epoch + 1) |> repo.update() do
      # The existing attempt ended before its input closed. A new claim would
      # change its committed domain state, including during tenant suspension.
      attempt = RoundState.get(run.model_response).workflow_attempt
      run = %{run | epoch: workspace.epoch, spec: %{request_context: %{"attempt" => attempt}}}
      finalize_in_tx(repo, run, outcome, nil)
    else
      %ActorEvent{completed_at: %DateTime{}} = event ->
        {:ok, %{status: :completed, actor_event: event}}

      {:error, _} = error ->
        error

      _not_committed ->
        {:ok, :not_committed}
    end
  end

  defp committed_workflow_outcome(run) do
    Enum.find_value(run.round_calls, fn call ->
      case run.results[call_id(call)] || committed_tool_result(run, call) do
        %ToolResult{outcome: outcome} = result when outcome in [:sleeping, :submitted] ->
          if ToolResult.ends_turn?(result), do: outcome

        _ ->
          nil
      end
    end)
  end

  defp committed_tool_result(run, call) do
    case Receipts.fetch(response_id(run.model_response), call_id(call)) do
      {:ok, %Receipts{agent_uid: uid, session_id: session} = receipt}
      when uid == run.agent_uid and session == run.session_id ->
        ToolResult.decode(receipt.result, receipt.inserted_at)

      _ ->
        nil
    end
  end

  @spec reject_input_in_tx(module(), ActorEvent.Run.t(), Outcome.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def reject_input_in_tx(repo, snapshot, outcome, reason) do
    with {:ok, _} <-
           Ankole.SignalsGateway.ActorRuntime.SessionWorkspaces.ensure_in_tx(
             repo,
             snapshot.agent_uid,
             snapshot.session_id
           ),
         workspace <-
           repo.one(
             from w in ActorSessionWorkspace,
               where: w.agent_uid == ^snapshot.agent_uid and w.session_id == ^snapshot.session_id,
               lock: "FOR UPDATE"
           ),
         %ActorEvent{} = event <- Actors.lock_actor_event_in_tx(repo, snapshot.id) do
      if event.completed_at || event.input_state != "open" do
        {:ok, %{status: :already_completed, actor_event: event}}
      else
        with {:ok, conversation} <-
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 event.agent_uid,
                 event.session_id,
                 event
               ),
             {:ok, workspace} <-
               workspace |> Ecto.Changeset.change(epoch: workspace.epoch + 1) |> repo.update() do
          run = %Run{
            agent_uid: event.agent_uid,
            session_id: event.session_id,
            actor_event_id: event.id,
            epoch: workspace.epoch,
            event: event,
            conversation: conversation,
            workspace_id: workspace.id
          }

          finalize_recovered_in_tx(repo, run, outcome, reason)
        end
      end
    else
      nil -> {:ok, %{status: :idle}}
      error -> error
    end
  end

  @spec finalize_in_tx(module(), Run.t(), Outcome.t(), term()) :: {:ok, map()} | {:error, term()}
  def finalize_in_tx(repo, run, outcome, reason) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- Fence.check_in_tx(repo, run),
         {:ok, _} <- end_model_in_tx(repo, run, outcome, now),
         {:ok, {run, journal}} <- Run.record_pending_in_tx(repo, run),
         {:ok, events} <- lock_applied_events(repo, run, outcome),
         :ok <- live_sources(repo, events, outcome, now),
         {:ok, completion} <- completion(run, outcome),
         reply_event = Presentation.reply_event(events, run.event),
         {:ok, outboxes} <-
           commit_terminal_in_tx(repo, run, events, reply_event, completion, outcome, reason, now) do
      Receipts.delete_run_in_tx(repo, run)

      {:ok,
       %{
         status: :completed,
         outcome: outcome,
         journal: journal,
         final_text: completion.final_text,
         outboxes: outboxes,
         actor_event: repo.get!(ActorEvent, run.actor_event_id),
         reply_event: reply_event,
         run: run
       }}
    end
  end

  defp completion(run, outcome) do
    if Outcome.class(outcome) == :reply do
      with {:ok, completion} <-
             AIGatewayLink.load_turn_completion(run, external_anchor(run.anchor)),
           {:ok, completion} <- type(run).project_completion(run, completion) do
        if is_binary(completion.final_text) or is_map(completion.clarify_prompt) or
             completion.attachments != [],
           do: {:ok, completion},
           else: {:error, :turn_completion_has_no_user_visible_projection}
      end
    else
      {:ok, %{final_text: nil, clarify_prompt: nil, attachments: []}}
    end
  end

  defp end_model_in_tx(repo, run, outcome, now) when outcome in [:stopped, :dead_letter] do
    AIGatewayLink.retract_generating_turn_in_tx(
      repo,
      run,
      run.actor_event_id,
      now,
      Outcome.encode(outcome)
    )
  end

  defp end_model_in_tx(_repo, _run, _outcome, _now), do: {:ok, nil}

  defp lock_applied_events(repo, run, outcome) do
    with {:ok, history} <- input_history(run) do
      states = RoundState.load(history)

      injected =
        Enum.flat_map(
          history,
          &RoundState.for_message(states, &1).steer_event_ids
        )

      ids =
        Enum.uniq(
          [run.actor_event_id | injected] ++
            if(outcome == :stopped, do: run.steer_event_ids, else: [])
        )

      # Withdrawal deletes input, but its tool history remains authoritative.
      events = Enum.map(ids, &Actors.lock_actor_event_in_tx(repo, &1)) |> Enum.reject(&is_nil/1)

      if Enum.all?(
           events,
           &match?(
             %ActorEvent{agent_uid: uid, session_id: session}
             when uid == run.agent_uid and session == run.session_id,
             &1
           )
         ), do: {:ok, events}, else: {:error, :input_unavailable}
    end
  end

  defp commit_terminal_in_tx(
         repo,
         _run,
         events,
         reply_event,
         _completion,
         :dead_letter,
         reason,
         now
       ) do
    with {:ok, _} <-
           update_events(events, &Actors.mark_event_dead_letter_in_tx(repo, &1, now, reason)),
         {:ok, _} <- Notices.commit_dead_letter_notice_in_tx(repo, reply_event, reason),
         do: {:ok, %{}}
  end

  defp commit_terminal_in_tx(
         repo,
         _run,
         events,
         reply_event,
         _completion,
         :stopped,
         :actor_event_context_canceled,
         now
       ) do
    with {:ok, notice} <-
           Notices.commit_context_withdrawal_notice_in_tx(repo, events, reply_event, now),
         {:ok, _} <- update_events(events, &Actors.mark_event_completed_in_tx(repo, &1, now)) do
      {:ok, %{attachments: [], clarify: nil, finals: List.wrap(notice)}}
    end
  end

  defp commit_terminal_in_tx(repo, run, events, reply_event, completion, outcome, _reason, now) do
    visible_outcome =
      if Outcome.class(outcome) in [:canceled, :committed], do: :silent, else: outcome

    with {:ok, outboxes} <-
           Presentation.commit_outboxes_in_tx(repo, reply_event, completion, visible_outcome, now),
         {:ok, _} <-
           update_events(events, fn event ->
             if Outcome.class(outcome) in [:canceled, :committed],
               do: Actors.mark_event_completed_in_tx(repo, event, now),
               else:
                 Actors.mark_turn_event_completed_in_tx(
                   repo,
                   event,
                   now,
                   external_anchor(run.anchor),
                   Outcome.encode(outcome)
                 )
           end) do
      {:ok, outboxes}
    end
  end

  defp update_events(events, operation) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, updated} ->
      if event.completed_at || event.input_state != "open" do
        {:cont, {:ok, [event | updated]}}
      else
        case operation.(event) do
          {:ok, event} -> {:cont, {:ok, [event | updated]}}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp live_sources(_repo, _events, :stopped, _now), do: :ok

  defp live_sources(repo, events, _outcome, now) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Actors.ensure_event_source_live_in_tx(repo, event, now) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp external_anchor(nil), do: nil
  defp external_anchor("resp_" <> _ = id), do: id
  defp external_anchor(id), do: "resp_#{id}"

  defp input_history(run) do
    with {:ok, tail} <- AIGateway.conversation_tail(run.conversation, run.actor_event_id),
         do: {:ok, tail.responses}
  end
end
