defmodule Ankole.Sessions.Run do
  @moduledoc """
  Rebuilds one run from its inbox and tape and commits Turn decisions.

  The workspace epoch serializes these decisions with tool transactions.
  A process contains no authoritative progress that must survive its exit.
  Terminal input, domain outcomes and visible replies commit under this fence.
  """

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolResultJournal
  alias Ankole.Sessions.RoundState
  alias Ankole.Sessions.Run.Tape
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Receipt
  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.Notices
  alias Ankole.Sessions.Outcome
  alias Ankole.Sessions.Presentation
  alias Ankole.Sessions.ToolResult
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Sessions.SessionWorkspace

  @type t :: %__MODULE__{}

  @enforce_keys [:agent_uid, :session_id, :signal_id, :epoch, :event]
  defstruct [
    :agent_uid,
    :session_id,
    :signal_id,
    :epoch,
    :event,
    :delivered_event,
    :conversation,
    :workspace_id,
    :spec,
    :context,
    :instructions,
    :model_response,
    :anchor,
    :span,
    :repair_failure,
    kind: :main,
    tools: [],
    hosted_tools: [],
    input: [],
    calls: [],
    round_calls: [],
    results: %{},
    receipts: %{},
    follow_ups: [],
    wait_event_ids: [],
    steer_event_ids: [],
    pending_event_ids: [],
    pages: %{},
    todo: %{},
    web_cache: %{},
    iteration: 0,
    nudged: false,
    repaired: false,
    truncated_rounds: 0,
    saw_tool_results: false,
    outcome: :loop_finished,
    recovered?: false,
    visible_delivery?: false,
    repeated_failure: nil
  ]

  def type(%{kind: kind}), do: type(kind)
  def type(%Signal{} = event), do: event |> kind() |> type()
  def type(:main), do: Ankole.Sessions.Main
  def type(:ambient), do: Ankole.Sessions.Ambient
  def type(:scheduled), do: Ankole.Sessions.Scheduled
  def type(:workflow_task), do: Ankole.Sessions.WorkflowTask

  @spec kind(String.t() | map()) :: :workflow_task | :ambient | :scheduled | :main
  def kind(%Signal{} = event) do
    if Signal.produced_by_kernel?(event), do: kernel_kind(event), else: :main
  end

  def kind(%{}), do: :main

  def kind(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:workflow_task, _} -> :workflow_task
      _ -> :main
    end
  end

  defp kernel_kind(%{session_id: session, type: type} = event) do
    case kind(session) do
      :main when type == "im.message.may_intervene" ->
        if is_binary(event.conversation_id) &&
             Ankole.Conversations.get_conversation!(event.conversation_id),
           do: :ambient,
           else: :main

      :main when type in ["cron.fire", "check_back_later.wakeup"] ->
        if Ankole.Sessions.Scheduled.produced_signal?(event), do: :scheduled, else: :main

      kind ->
        kind
    end
  end

  @spec rebuild(map(), DateTime.t()) ::
          {:ok, :idle | %{event: Signal.t(), delay_ms: non_neg_integer()}}
  def rebuild(key, now \\ DateTime.utc_now(:microsecond)) do
    case Queue.next_ready_event(key.agent_uid, key.session_id, now) do
      nil ->
        {:ok, :idle}

      event ->
        {:ok, %{event: event, delay_ms: retry_delay_ms(event, now)}}
    end
  end

  @spec retry_delay_ms(Signal.t(), DateTime.t()) :: non_neg_integer()
  def retry_delay_ms(%Signal{status: :queued, available_at: due}, now),
    do: max(DateTime.diff(due, now, :millisecond), 0)

  def retry_delay_ms(%Signal{status: :running} = event, now) do
    retry_at =
      DateTime.add(
        event.last_attempt_at,
        backoff_seconds(event.attempt_count - event.provider_capacity_attempt_count, :execution)
      )

    due = if DateTime.after?(event.available_at, retry_at), do: event.available_at, else: retry_at
    max(DateTime.diff(due, now, :millisecond), 0)
  end

  @doc "Commits the retry time and charges only execution failures to the failure budget."
  def defer_retry(run, error, now \\ DateTime.utc_now(:microsecond)) do
    Ankole.Repo.transact_top_level(
      fn -> defer_retry_in_tx(run, error, now) end,
      after_commit: {__MODULE__, :publish_retry}
    )
    |> Ankole.Errors.reason()
  end

  @doc "Publishes the Session status after a committed retry."
  def publish_retry(%Signal{} = event),
    do: Ankole.Sessions.Events.publish_status(event.agent_uid, event.session_id)

  @doc "Returns the retry Signal for publication by the transaction owner after commit."
  def defer_retry_in_tx(run, error, now) do
    capacity? = Ankole.AIGateway.FailureDiagnostics.provider_capacity?(error)

    with :ok <- Fence.check_in_tx(run),
         %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(run.signal_id) do
      if event.available_at != run.event.available_at do
        {:ok, event}
      else
        count = event.provider_capacity_attempt_count + if(capacity?, do: 1, else: 0)
        attempt = if capacity?, do: count, else: event.attempt_count - count
        class = if capacity?, do: :provider_capacity, else: :execution

        due =
          Ankole.Sessions.TurnErrorClassifier.credential_pool_retry_at(
            error,
            now
          ) || DateTime.add(now, backoff_seconds(attempt, class))

        with {:ok, event} <-
               Ankole.Signals.transition_in_tx(event, :defer, %{
                 available_at: due,
                 provider_capacity?: capacity?
               }),
             :ok <-
               Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
                 %{agent_uid: run.agent_uid, session_id: run.session_id},
                 due
               ),
             do: {:ok, event}
      end
    end
  end

  def backoff_seconds(attempt, class),
    do:
      Ankole.Sessions.TurnErrorClassifier.delay_seconds(
        :conversation,
        attempt,
        class
      )

  @doc "Resets transient fields; restore/1 rebuilds them from durable facts."
  def reset(run) do
    %__MODULE__{
      agent_uid: run.agent_uid,
      session_id: run.session_id,
      signal_id: run.signal_id,
      epoch: run.epoch,
      kind: run.kind,
      event: run.event,
      delivered_event: run.delivered_event,
      conversation: run.conversation,
      workspace_id: run.workspace_id,
      spec: run.spec,
      span: run.span,
      web_cache: run.web_cache
    }
  end

  defdelegate restore(run), to: Tape
  defdelegate restore_in_tx(run), to: Tape
  defdelegate record_round(run), to: Tape
  defdelegate record_round_in_tx(run), to: Tape
  defdelegate record_pending_in_tx(run), to: Tape

  @doc """
  Injects the pending input that `include?` selects, in queue order up to the
  first input that cannot join a running turn, and appends it to the model input.
  """
  @spec inject_pending(t(), (Signal.t() -> as_boolean(term()))) ::
          {:ok, [Signal.t()], t()} | {:error, term()}
  def inject_pending(run, include?) do
    events =
      Queue.due(run)
      |> Enum.filter(&(&1.id in run.pending_event_ids and include?.(&1)))
      |> Enum.reject(&Ankole.Sessions.Commands.queued_followup?/1)
      |> Enum.take_while(
        &(Ankole.Sessions.Commands.injectable?(&1) and
            Ankole.Conversations.ModelPreferences.compatible?(
              &1,
              run.spec.model_ref["profile"] || "primary"
            ))
      )

    with {:ok, injected} <- inject(run, events) do
      ids = Enum.map(injected, & &1.id)

      {:ok, injected,
       %{
         run
         | input:
             run.input ++
               Enum.flat_map(injected, &Ankole.Sessions.Prompt.steer(run, &1, nil)),
           steer_event_ids: Enum.uniq(run.steer_event_ids ++ ids),
           pending_event_ids: run.pending_event_ids -- ids
       }}
    end
  end

  @spec inject(t(), [Signal.t()], DateTime.t()) :: {:ok, [Signal.t()]} | {:error, term()}
  def inject(run, events, now \\ DateTime.utc_now(:microsecond)) do
    Ankole.Repo.transact_top_level(fn -> inject_in_tx(run, events, now) end)
    |> Ankole.Errors.reason()
    |> after_injection(run)
  end

  def inject_in_tx(run, events, now) do
    :ok = Ankole.Files.lock_tree_in_tx()

    ids = Enum.map(events, & &1.id)

    events =
      Ankole.Signals.list_signals!(query: [filter: [id: [in: ids]], sort: [queue_sequence: :asc]])

    :ok = lock_native_participants_in_tx(run, events)
    :ok = Ankole.Principals.WorkAccess.lock_authorizers_in_tx(events)

    with :ok <- Ankole.Sessions.Notices.lock_work_in_tx(run),
         :ok <- Queue.lock_session_in_tx(run.agent_uid, run.session_id),
         :ok <- Fence.check_in_tx(run) do
      events
      |> Enum.reduce_while({:ok, {[], []}}, fn event, {:ok, {injected, completed}} ->
        case inject_event_in_tx(run, event, now) do
          {:ok, nil} -> {:cont, {:ok, {injected, completed}}}
          {:ok, %Signal{} = current} -> {:cont, {:ok, {[current | injected], completed}}}
          {:ok, result} -> {:cont, {:ok, {injected, [result | completed]}}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, {events, completed}} -> {:ok, {Enum.reverse(events), Enum.reverse(completed)}}
        error -> error
      end
    end
  end

  defp inject_event_in_tx(run, event, now) do
    with %Signal{agent_uid: uid, session_id: session, status: live_status} =
           current
         when live_status in [:queued, :running] <-
           Ankole.Signals.lock_signal_in_tx(event.id),
         true <- uid == run.agent_uid and session == run.session_id,
         true <-
           Ankole.Principals.WorkAccess.fields(current) ==
             Ankole.Principals.WorkAccess.fields(event),
         false <- Ankole.Sessions.Commands.queued_followup?(current),
         true <-
           Ankole.Conversations.ModelPreferences.compatible?(
             current,
             run.spec.model_ref["profile"] || "primary"
           ),
         {:ok, %Signal{status: live_status} = authorized}
         when live_status in [:queued, :running] <-
           Ankole.Sessions.Admission.authorize_event_in_tx(current) do
      Ankole.Signals.transition_in_tx(authorized, :start_attempt, %{last_attempt_at: now})
    else
      {:error, _} = error -> error
      {:ok, %{signal: _} = result} -> {:ok, result}
      {:ok, %Signal{} = current} -> {:ok, %{signal: current}}
      _closed -> {:ok, nil}
    end
  end

  @spec finalize(t(), Outcome.t(), term()) :: {:ok, map()} | {:error, term()}
  def finalize(run, outcome \\ :loop_finished, reason \\ nil) do
    with {:ok, images} <- prepare_reply_images(run, outcome) do
      attributes =
        Ankole.Observability.signal_attributes(run.event)
        |> Map.put("ankole.session.epoch", run.epoch)

      Ankole.Observability.stage(
        "session.finalize.commit",
        attributes,
        fn ->
          Ankole.Repo.transact_top_level(fn ->
            finalize_in_tx(run, outcome, reason, images)
          end)
          |> Ankole.Errors.reason()
        end,
        run.span
      )
      |> after_finalization()
    end
  end

  defp prepare_reply_images(run, outcome) do
    if Outcome.class(outcome) == :reply do
      case Presentation.prepare_generated_images(run, external_anchor(run.anchor)) do
        {:error, _reason} = error ->
          # A completed run can outlive its model artifacts. Preserve the
          # authoritative closed/stale rejection when preparation fails, without
          # adding a transaction to successful preparation.
          with {:ok, :live} <- check_live(run, :update), do: error

        prepared ->
          prepared
      end
    else
      {:ok, %{}}
    end
  end

  def after_finalization({:ok, result}) do
    Repo.assert_outside_transaction!()

    result =
      case Map.get(result, :workflow_transition) do
        nil ->
          result

        transition ->
          {:ok, cleaned} = Ankole.Workflow.cleanup_terminal_transition({:ok, transition})
          Map.put(result, :workflow_transition, cleaned)
      end

    Presentation.publish_committed(result)

    case result do
      %{run: %__MODULE__{} = run} ->
        Enum.each(result.input_signal_ids, fn id ->
          Ankole.Observability.stage(
            "session.input.completed",
            Ankole.Observability.signal_attributes(run.event)
            |> Map.put("ankole.signal.id", id)
            |> Map.put("ankole.signal.root_id", run.signal_id)
            |> Map.put("ankole.signal.reply_id", result.reply_event.id)
            |> Map.put("ankole.session.epoch", run.epoch),
            fn -> :ok end,
            run.span
          )
        end)

        Enum.each(result.posted.intents, fn intent ->
          Ankole.Observability.stage(
            "session.delivery.committed",
            %{
              "ankole.tenant.id" => intent.tenant_id,
              "ankole.signal.id" => intent.source_signal_id,
              "ankole.signal.root_id" => run.signal_id,
              "ankole.delivery.key" => intent.outbound_key,
              "ankole.ai_gateway.response_id" => intent.ai_message_id
            },
            fn -> :ok end,
            run.span
          )
        end)

        if result.journal,
          do: ToolResultJournal.publish_tool_result_events(result.journal.message)

        Presentation.stop(run)

      _ ->
        :ok
    end

    {:ok, result}
  end

  def after_finalization(result), do: result

  defp after_injection({:ok, {events, completed}}, run) do
    Enum.each(completed, &after_finalization({:ok, &1}))

    Enum.each(events, fn event ->
      Ankole.Observability.stage(
        "session.input.injected",
        Ankole.Observability.signal_attributes(event)
        |> Map.put("ankole.signal.root_id", run.signal_id)
        |> Map.put("ankole.session.epoch", run.epoch),
        fn -> :ok end,
        run.span
      )

      Ankole.Sessions.Events.publish_status(event.agent_uid, event.session_id)
    end)

    {:ok, events}
  end

  defp after_injection(error, _run), do: error

  @spec finalize_recovered_in_tx(t(), Outcome.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def finalize_recovered_in_tx(run, outcome, reason) do
    with :ok <- lock_for_write_in_tx(run),
         :ok <- Fence.check_in_tx(run),
         {:ok, _} <- end_model_in_tx(run, :stopped, DateTime.utc_now(:microsecond)),
         {:ok, {_state, run}} <- Tape.restore_tape(run),
         do: finalize_in_tx(run, outcome, reason)
  end

  @doc "Closes an admitted Workflow input whose terminating tool already committed."
  @spec finalize_committed_workflow_input_in_tx(Signal.t()) ::
          {:ok, :not_committed | map()} | {:error, term()}
  def finalize_committed_workflow_input_in_tx(snapshot) do
    :ok = Ankole.Files.lock_tree_in_tx()

    with :ok <- lock_workflow_in_tx(snapshot),
         %SessionWorkspace{} = workspace <- Fence.lock_workspace_in_tx(snapshot),
         %Signal{status: live_status, last_attempt_at: %DateTime{}} =
           event
         when live_status in [:queued, :running] <-
           Ankole.Signals.lock_signal_in_tx(snapshot.id),
         %{} = conversation <-
           AIGateway.active_conversation_for_update(
             event.agent_uid,
             event.session_id
           ),
         {:ok, {_state, run}} <-
           Tape.restore_tape(
             %__MODULE__{
               agent_uid: event.agent_uid,
               session_id: event.session_id,
               signal_id: event.id,
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
         {:ok, workspace} <- Ankole.Ash.update_atomic(workspace, :advance_epoch) do
      # The existing attempt ended before its input closed. A new claim would
      # change its committed domain state, including during tenant suspension.
      attempt = RoundState.get(run.model_response).workflow_attempt
      run = %{run | epoch: workspace.epoch, spec: %{request_context: %{"attempt" => attempt}}}
      finalize_in_tx(run, outcome, nil)
    else
      %Signal{status: :completed} = event ->
        {:ok, %{status: :completed, signal: event}}

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
      {:ok, %Receipt{agent_uid: uid, session_id: session} = receipt}
      when uid == run.agent_uid and session == run.session_id ->
        ToolResult.decode(receipt.result, receipt.inserted_at)

      _ ->
        nil
    end
  end

  @spec reject_input_in_tx(Signal.t(), Outcome.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def reject_input_in_tx(snapshot, outcome, reason) do
    :ok = Ankole.Files.lock_tree_in_tx()

    humans =
      Ankole.Signals.session_queue(snapshot.agent_uid, snapshot.session_id, started?: true)
      |> Enum.map(& &1.human_uid)

    with :ok <-
           Ankole.Conversations.lock_native_participants_in_tx(snapshot, [
             snapshot.human_uid | humans
           ]),
         {:ok, _} <-
           Ankole.Sessions.Workspaces.ensure_in_tx(
             snapshot.agent_uid,
             snapshot.session_id
           ),
         workspace <- Fence.lock_workspace_in_tx(snapshot),
         %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(snapshot.id) do
      if event.status not in [:queued, :running] do
        {:ok, %{status: :already_completed, signal: event}}
      else
        with {:ok, conversation} <-
               ModelHistory.ensure_and_lock_conversation_in_tx(
                 event.agent_uid,
                 event.session_id,
                 event
               ),
             {:ok, workspace} <- Ankole.Ash.update_atomic(workspace, :advance_epoch) do
          run = %__MODULE__{
            agent_uid: event.agent_uid,
            session_id: event.session_id,
            signal_id: event.id,
            epoch: workspace.epoch,
            event: event,
            conversation: conversation,
            workspace_id: workspace.id
          }

          finalize_recovered_in_tx(run, outcome, reason)
        end
      end
    else
      nil -> {:ok, %{status: :idle}}
      error -> error
    end
  end

  @spec finalize_in_tx(t(), Outcome.t(), term()) :: {:ok, map()} | {:error, term()}
  def finalize_in_tx(run, outcome, reason, images \\ %{}) do
    :ok = Ankole.Files.lock_tree_in_tx()
    now = DateTime.utc_now(:microsecond)

    with :ok <- lock_generated_image_root_in_tx(run, images),
         :ok <- lock_for_write_in_tx(run),
         :ok <- Queue.lock_session_in_tx(run.agent_uid, run.session_id),
         :ok <- Fence.check_in_tx(run),
         {:ok, _} <- end_model_in_tx(run, outcome, now),
         {:ok, {run, journal}} <- record_pending_in_tx(run),
         {:ok, events} <- lock_applied_events(run, outcome),
         :ok <- live_sources(events, outcome, now),
         {:ok, completion} <- completion(run, outcome, reason, images),
         reply_event = Presentation.reply_event(events, run.event),
         {:ok, posted} <-
           commit_terminal_in_tx(run, events, reply_event, completion, outcome, reason, now) do
      Receipts.delete_run_in_tx(run)

      {:ok,
       %{
         status: :completed,
         outcome: outcome,
         journal: journal,
         final_text: completion.final_text,
         completion: completion,
         input_signal_ids: Enum.map(events, & &1.id),
         posted: posted,
         signal: Ankole.Signals.get_signal!(run.signal_id),
         reply_event: reply_event,
         run: run
       }}
    end
  end

  defp lock_generated_image_root_in_tx(run, images) do
    if map_size(images) > 0 and
         is_nil(Ankole.Conversations.ExternalTarget.origin(run.conversation)) do
      with {:ok, root} <- Ankole.Files.private_root(run.agent_uid),
           do: Ankole.Files.lock_root_ids_in_tx([root.id])
    else
      :ok
    end
  end

  @doc "Locks domain work and participating Sessions before the epoch fence."
  def lock_for_write_in_tx(%{kind: :workflow_task} = run) do
    with :ok <- Ankole.Files.lock_tree_in_tx(), do: lock_workflow_in_tx(run)
  end

  def lock_for_write_in_tx(run) do
    with :ok <- Ankole.Files.lock_tree_in_tx(),
         :ok <- lock_native_participants_in_tx(run),
         do: Queue.lock_session_in_tx(run.agent_uid, run.session_id)
  end

  @doc false
  def lock_native_participants_in_tx(run, extra_events \\ []) do
    events =
      Ankole.Signals.list_signals!(query: [filter: [id: [in: run.steer_event_ids]]])

    Ankole.Conversations.lock_native_participants_in_tx(
      run,
      Enum.map([run.event | events ++ extra_events], & &1.human_uid)
    )
  end

  defp lock_workflow_in_tx(run) do
    with {:ok, %{run: workflow}} <-
           Ankole.Workflow.Slot.lock_session_work_in_tx(run.agent_uid, run.session_id) do
      Queue.lock_sessions_in_tx([
        {run.agent_uid, run.session_id},
        {run.agent_uid, workflow.owner_session_id}
      ])
    end
  end

  defp completion(run, outcome, reason, images) do
    if Outcome.class(outcome) == :reply do
      with {:ok, completion} <-
             Presentation.load_completion_in_tx(run, external_anchor(run.anchor), images),
           {:ok, completion} <- type(run).project_completion(run, completion) do
        if is_binary(completion.final_text) or is_map(completion.clarify_prompt) or
             is_map(completion[:action_card_prompt]) or
             completion.attachments != [],
           do: {:ok, completion},
           else: {:error, :turn_completion_has_no_user_visible_projection}
      end
    else
      completion = %{
        final_text: nil,
        clarify_prompt: nil,
        action_card_prompt: nil,
        attachments: []
      }

      if outcome in [:stopped, :dead_letter] and native_turn?(run) do
        status =
          if outcome == :stopped and is_nil(reason),
            do: "stopped",
            else: "failed"

        with {:ok, execution} <-
               Presentation.execution_in_tx(run, status),
             do: {:ok, Map.put(completion, :execution, execution)}
      else
        {:ok, completion}
      end
    end
  end

  defp native_turn?(run) do
    case Ankole.Sessions.Key.parse(run.session_id) do
      {:conversation, id} ->
        match?(%{kind: :native}, Ankole.Conversations.get_conversation!(id))

      _ ->
        false
    end
  end

  defp end_model_in_tx(run, outcome, now) when outcome in [:stopped, :dead_letter] do
    ModelHistory.retract_generating_turn_in_tx(
      run,
      run.signal_id,
      now,
      Outcome.encode(outcome)
    )
  end

  defp end_model_in_tx(_run, _outcome, _now), do: {:ok, nil}

  defp lock_applied_events(run, outcome) do
    with {:ok, tail} <-
           AIGateway.visible_response_suffix(
             run.agent_uid,
             run.conversation.id,
             {"signal_id", run.signal_id}
           ) do
      states = RoundState.load(tail.responses)
      injected = Tape.taped_steer_event_ids(tail.responses, states)

      ids =
        Enum.uniq(
          [run.signal_id | injected] ++
            if(outcome == :stopped, do: run.steer_event_ids, else: [])
        )

      # Withdrawal deletes input, but its tool history remains authoritative.
      events =
        Enum.map(ids, &Ankole.Signals.lock_signal_in_tx(&1)) |> Enum.reject(&is_nil/1)

      if Enum.all?(
           events,
           &match?(
             %Signal{agent_uid: uid, session_id: session}
             when uid == run.agent_uid and session == run.session_id,
             &1
           )
         ), do: {:ok, events}, else: {:error, :input_unavailable}
    end
  end

  defp commit_terminal_in_tx(
         _run,
         events,
         reply_event,
         completion,
         :dead_letter,
         reason,
         now
       ) do
    with {:ok, _} <-
           update_events(events, &Queue.mark_event_dead_letter_in_tx(&1, now, reason)),
         {:ok, notice} <- Notices.commit_dead_letter_notice_in_tx(reply_event, reason, completion) do
      {:ok, notice}
    end
  end

  defp commit_terminal_in_tx(
         _run,
         events,
         reply_event,
         %{execution: _} = completion,
         :stopped,
         reason,
         now
       )
       when is_nil(reason) do
    text = Ankole.I18n.t("conversations.delivery.reply.command_stopped")

    with {:ok, notice} <-
           Notices.post_in_tx(
             reply_event,
             :stopped,
             text,
             %{"reason" => reason},
             completion
           ),
         {:ok, _} <- update_events(events, &Queue.mark_event_completed_in_tx(&1, now)) do
      {:ok, notice}
    end
  end

  defp commit_terminal_in_tx(run, events, reply_event, completion, outcome, _reason, now) do
    visible_outcome =
      if Outcome.class(outcome) in [:canceled, :committed], do: :silent, else: outcome

    with {:ok, posted} <-
           Presentation.post_in_tx(reply_event, %Ankole.Conversations.Statement{
             signal: reply_event,
             completion: completion,
             outcome: visible_outcome,
             now: now
           }),
         {:ok, _} <-
           update_events(events, fn event ->
             if Outcome.class(outcome) in [:canceled, :committed],
               do: Queue.mark_event_completed_in_tx(event, now),
               else:
                 Queue.mark_turn_event_completed_in_tx(
                   event,
                   now,
                   external_anchor(run.anchor),
                   Outcome.encode(outcome)
                 )
           end) do
      {:ok, posted}
    end
  end

  defp update_events(events, operation) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, updated} ->
      if event.status not in [:queued, :running] do
        {:cont, {:ok, [event | updated]}}
      else
        case operation.(event) do
          {:ok, event} -> {:cont, {:ok, [event | updated]}}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp live_sources(_events, :stopped, _now), do: :ok

  defp live_sources(events, _outcome, now) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Queue.ensure_event_source_live_in_tx(event, now) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp external_anchor(nil), do: nil
  defp external_anchor("resp_" <> _ = id), do: id
  defp external_anchor(id), do: "resp_#{id}"

  def refund(run, mode) when mode in [:shutdown, :stale_driver] do
    Ankole.Repo.transact_top_level(fn -> refund_in_tx(run, mode) end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def refund_in_tx(run, mode) do
    workspace = Fence.lock_workspace_in_tx(run)

    eligible? =
      workspace &&
        ((mode == :shutdown and workspace.epoch == run.epoch) or
           (mode == :stale_driver and workspace.epoch > run.epoch))

    with true <- eligible?,
         %Signal{status: live_status} = event
         when live_status in [:queued, :running] <-
           Ankole.Signals.lock_signal_in_tx(run.signal_id) do
      Ankole.Signals.transition_in_tx(event, :refund_attempt)
    else
      _ -> {:ok, :unchanged}
    end
  end

  defp check_live(run, lock) do
    Ankole.Repo.transact_top_level(fn -> check_live_in_tx(run, lock) end)
    |> Ankole.Errors.reason()
  end

  @doc false
  def check_live_in_tx(run, lock) do
    with :ok <- Fence.check_in_tx(run, lock), do: {:ok, :live}
  end

  @spec metadata(t()) :: map()
  def metadata(run), do: %{"signal_id" => run.signal_id}

  @spec executable_calls(map()) :: [map()]
  def executable_calls(message) do
    message
    |> response_output()
    |> Enum.filter(&(ResponseItems.client_call_item?(&1) and ResponseItems.executable_call?(&1)))
  end

  @spec visible_delivery?(t(), map(), ToolResult.t()) :: boolean()
  def visible_delivery?(run, call, result) do
    tool = Ankole.Sessions.ToolCatalog.find(run, call)
    result.is_error != true and tool != nil and tool.visible_delivery
  end

  @spec tool_identity(t(), map()) :: String.t()
  def tool_identity(run, call), do: "#{response_id(run.model_response)}:#{call_id(call)}"

  @spec call_id(map()) :: String.t()
  def call_id(call), do: call[ResponseItems.pair_identity_field(call)]

  def text(%{model_response: nil}), do: ""

  def text(run),
    do: Ankole.Conversations.Delivery.Text.visible_text(response_output(run.model_response)) || ""

  def user(text),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  @spec response_id(map() | nil) :: String.t() | nil
  def response_id(nil), do: nil
  def response_id(%{id: id}), do: "resp_#{id}"
  @doc "Returns whether the output token limit cut off a round that contains tool calls."
  @spec truncated?(map()) :: boolean()
  def truncated?(message),
    do:
      message.metadata["incomplete_details"]["reason"] == "max_output_tokens" and
        Enum.any?(response_output(message), &ResponseItems.call_item?/1)

  @spec response_output(map()) :: [map()]
  def response_output(message),
    do: Enum.drop(message.content, message.metadata["request_item_count"] || 0)

  @spec output(map(), ToolResult.t()) :: map()
  def output(call, result) do
    %{
      "type" => ResponseItems.expected_output_type(call["type"]),
      "call_id" => call_id(call),
      "output" => result.output
    }
  end
end
