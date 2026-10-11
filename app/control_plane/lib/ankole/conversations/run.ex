defmodule Ankole.Conversations.Run do
  @moduledoc """
  Rebuilds one run from its inbox and tape and commits driver decisions.

  The workspace epoch serializes these decisions with tool transactions.
  A process contains no authoritative progress that must survive its exit.
  """

  import Ecto.Query

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Conversations.Fence
  alias Ankole.Conversations.Receipts
  alias Ankole.Conversations.Notices
  alias Ankole.Conversations.Presentation
  alias Ankole.Conversations.ToolResult
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace

  @type t :: %__MODULE__{}

  @enforce_keys [:agent_uid, :session_id, :actor_event_id, :epoch, :event]
  defstruct [
    :agent_uid,
    :session_id,
    :actor_event_id,
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
    :job,
    :job_ref,
    :job_worker,
    :job_mode,
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
    outcome: "loop_finished",
    recovered?: false,
    visible_delivery?: false,
    repeated_failure: nil
  ]

  @spec kind(String.t() | map()) :: :job | :workflow_task | :ambient | :scheduled | :main
  def kind(%{session_id: session, type: type}) do
    case kind(session) do
      :main when type == "im.message.may_intervene" -> :ambient
      :main when type in ["cron.fire", "check_back_later.wakeup"] -> :scheduled
      kind -> kind
    end
  end

  def kind("job:" <> _), do: :job
  def kind("wf_task:" <> _), do: :workflow_task
  def kind(_), do: :main

  @spec rebuild(map(), DateTime.t()) ::
          {:ok, :idle | %{event: ActorEvent.t(), delay_ms: non_neg_integer()}}
  def rebuild(key, now \\ DateTime.utc_now(:microsecond)) do
    case Actors.next_ready_event(key.agent_uid, key.session_id, now,
           strict_queue_order?: kind(key.session_id) == :job
         ) do
      nil ->
        {:ok, :idle}

      event ->
        {:ok, %{event: event, delay_ms: retry_delay_ms(event, now)}}
    end
  end

  @spec open_events(map(), DateTime.t()) :: [ActorEvent.t()]
  def open_events(key, now \\ DateTime.utc_now(:microsecond)) do
    ActorEvent
    |> where([e], e.agent_uid == ^key.agent_uid and e.session_id == ^key.session_id)
    |> where([e], e.input_state == "open" and is_nil(e.completed_at) and e.available_at <= ^now)
    |> order_by([e], asc: e.queue_sequence)
    |> Repo.all()
  end

  @spec retry_delay_ms(ActorEvent.t(), DateTime.t()) :: non_neg_integer()
  def retry_delay_ms(%ActorEvent{last_attempt_at: nil}, _now), do: 0

  def retry_delay_ms(event, now) do
    if kind(event.session_id) == :job,
      do: 0,
      else: input_retry_delay_ms(event, now)
  end

  defp input_retry_delay_ms(event, now) do
    due =
      if DateTime.compare(event.available_at, event.last_attempt_at) == :gt,
        do: event.available_at,
        else:
          DateTime.add(
            event.last_attempt_at,
            backoff_seconds(
              event.attempt_count - event.provider_capacity_attempt_count,
              :execution
            )
          )

    max(DateTime.diff(due, now, :millisecond), 0)
  end

  @doc "Commits the retry time and charges only execution failures to the failure budget."
  def defer_retry(run, error, now \\ DateTime.utc_now(:microsecond)) do
    Repo.transact(fn repo -> defer_retry_in_tx(repo, run, error, now) end)
  end

  defp defer_retry_in_tx(repo, run, error, now) do
    capacity? = Ankole.AIGateway.FailureDiagnostics.provider_capacity?(error)
    failure = Ankole.AIGateway.FailureDiagnostics.classify(error)

    with :ok <- Fence.check_in_tx(repo, run),
         %ActorEvent{} = event <- Actors.lock_actor_event_in_tx(repo, run.actor_event_id) do
      if event.available_at != run.event.available_at do
        {:ok, event}
      else
        count = event.provider_capacity_attempt_count + if(capacity?, do: 1, else: 0)
        attempt = if capacity?, do: count, else: event.attempt_count - count
        class = if capacity?, do: :provider_capacity, else: :execution
        due = gateway_retry_at(failure, now) || DateTime.add(now, backoff_seconds(attempt, class))

        with {:ok, event} <-
               event
               |> ActorEvent.changeset(%{
                 available_at: due,
                 provider_capacity_attempt_count: count
               })
               |> repo.update(),
             :ok <-
               Ankole.Conversations.Jobs.EnsureDriver.enqueue_in_tx(
                 repo,
                 %{agent_uid: run.agent_uid, session_id: run.session_id},
                 due
               ),
             do: {:ok, event}
      end
    end
  end

  defp gateway_retry_at(%{error_code: "credential_pool_exhausted", retry_at: retry_at}, now)
       when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, due, _} -> if DateTime.compare(due, now) == :gt, do: due
      _ -> nil
    end
  end

  defp gateway_retry_at(_failure, _now), do: nil

  @spec backoff_seconds(pos_integer(), atom()) :: non_neg_integer()
  def backoff_seconds(attempt, :provider_capacity),
    do: Enum.at([30, 120, 300, 750], min(max(attempt - 1, 0), 3))

  def backoff_seconds(attempt, _class),
    do: min(5 * Integer.pow(2, min(max(attempt - 1, 0), 5)), 120)

  @doc "Resets transient fields; restore/1 rebuilds them from durable facts."
  def reset(run) do
    %__MODULE__{
      agent_uid: run.agent_uid,
      session_id: run.session_id,
      actor_event_id: run.actor_event_id,
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

  @spec restore(t()) :: {:ok, {atom(), t()}} | {:error, term()}
  def restore(%__MODULE__{} = run) do
    with {:ok, :reclaimed} <- reclaim(run),
         {:ok, {state, run}} <- restore_tape(run) do
      receipts =
        if state == :executing_tools do
          response_id = response_id(run.model_response)

          Repo.all(from r in Receipts, where: r.response_id == ^response_id)
          |> Map.new(fn receipt ->
            {receipt.call_id, ToolResult.decode(receipt.result, receipt.inserted_at)}
          end)
        else
          %{}
        end

      {:ok, {state, %{run | receipts: receipts}}}
    end
  end

  defp restore_tape(run, restore_attempt? \\ true) do
    with {:ok, tail} <- AIGateway.conversation_tail(run.conversation, run.actor_event_id) do
      latest = List.last(tail.responses)
      loop = if latest, do: AIGateway.response_metadata(latest)["loop"] || %{}, else: %{}

      steers =
        tail.responses
        |> Enum.flat_map(&(AIGateway.response_metadata(&1)["loop"]["steer_event_ids"] || []))
        |> Enum.uniq()

      steers =
        retained_event_ids(steers)

      round_calls = if latest, do: executable_calls(latest), else: []

      calls =
        if latest && not truncated?(latest),
          do: Enum.reject(round_calls, &MapSet.member?(tail.recorded_call_ids, call_id(&1))),
          else: []

      latest_journal =
        Enum.find(
          Enum.reverse(tail.rows),
          &(latest && journal?(&1) && &1.previous_message_id == latest.id)
        )

      results = if latest_journal, do: journal_results(latest_journal), else: %{}

      run = %{
        run
        | model_response: latest,
          anchor: tail.leaf,
          iteration: loop["iteration"] || 0,
          nudged: loop["nudged"] || false,
          repaired: loop["repaired"] || false,
          repair_failure: loop["repair_failure"],
          truncated_rounds: loop["truncated_rounds"] || 0,
          outcome: loop["outcome"] || "loop_finished",
          pages: restore_pages(tail.rows),
          steer_event_ids: steers,
          calls: calls,
          round_calls: round_calls,
          results: results,
          saw_tool_results: Enum.any?(tail.rows, &journal?/1),
          recovered?: latest != nil,
          pending_event_ids:
            open_events(run)
            |> Enum.reject(&(&1.id == run.actor_event_id or &1.id in steers))
            |> Enum.map(& &1.id)
      }

      run = fold_tool_history(run, tail.rows)

      run = if restore_attempt?, do: restore_workflow_attempt(run, latest, loop), else: run

      state =
        cond do
          is_nil(run.model_response) -> :preparing
          run.calls != [] -> :executing_tools
          true -> :boundary
        end

      {:ok, {state, run}}
    end
  end

  defp restore_workflow_attempt(run, latest, loop) do
    # A Workflow retry keeps its trigger open and its committed effects in
    # the tape. The call attempt starts a new model turn on that same tape.
    if (run.kind == :workflow_task and latest) &&
         loop["workflow_attempt"] != run.spec.request_context["attempt"] do
      %{
        run
        | model_response: nil,
          calls: [],
          round_calls: [],
          results: %{},
          iteration: 0,
          repaired: false,
          repair_failure: nil,
          nudged: false,
          truncated_rounds: 0,
          saw_tool_results: false
      }
    else
      run
    end
  end

  defp input_history(run) do
    with {:ok, tail} <- AIGateway.conversation_tail(run.conversation, run.actor_event_id),
         do: {:ok, tail.responses}
  end

  defp retained_event_ids(ids) do
    retained =
      Repo.all(
        from e in ActorEvent,
          where: e.id in ^ids,
          select: e.id
      )
      |> MapSet.new()

    Enum.filter(ids, &MapSet.member?(retained, &1))
  end

  @spec record_round(t()) :: {:ok, map()} | {:error, term()}
  def record_round(run) do
    # Images that follow tool results enter history without a model request, so
    # they get the model's image rule here, before the transaction: history
    # keeps what the model sees, as it does for received images.
    follow_ups =
      AIGateway.adapt_images(
        run.agent_uid,
        run.follow_ups,
        Ankole.Conversations.Model.vision(run.spec.model_ref),
        subject_type: "agent",
        request_context: run.spec.request_context
      )

    Repo.transact(fn repo -> record_round_in_tx(repo, %{run | follow_ups: follow_ups}) end)
    |> publish_journal()
  end

  @spec record_round_in_tx(module(), t()) :: {:ok, map()} | {:error, term()}
  def record_round_in_tx(repo, run) do
    with :ok <- Fence.check_in_tx(repo, run),
         {:ok, workflow_call} <- lock_workflow_progress_in_tx(repo, run),
         {:ok, journal} <-
           AIGatewayLink.record_tool_results_and_complete_events_in_tx(
             repo,
             run.agent_uid,
             run.actor_event_id,
             run.wait_event_ids,
             %{
               "previous_response_id" => run.model_response.id,
               "input" =>
                 Enum.map(run.calls, &output(&1, Map.fetch!(run.results, call_id(&1)))) ++
                   run.follow_ups,
               "metadata" =>
                 put_in(
                   metadata(run),
                   ["loop", "results"],
                   Map.new(run.calls, fn call ->
                     id = call_id(call)
                     {id, ToolResult.journal_fields(Map.fetch!(run.results, id))}
                   end)
                 )
             }
           ),
         :ok <- touch_workflow_progress_in_tx(repo, workflow_call, journal) do
      Receipts.delete_round_in_tx(repo, run, response_id(run.model_response))
      {:ok, journal}
    end
  end

  defp lock_workflow_progress_in_tx(repo, %{kind: :workflow_task} = run) do
    context = run.spec.request_context

    with {:ok, call_id} <- Ankole.Workflow.parse_task_session_id(run.session_id) do
      Ankole.Workflow.lock_task_progress_in_tx(
        repo,
        call_id,
        run.agent_uid,
        run.session_id,
        context["attempt"]
      )
    end
  end

  defp lock_workflow_progress_in_tx(_repo, _run), do: {:ok, nil}

  defp touch_workflow_progress_in_tx(repo, call, %{disposition: :inserted}),
    do: Ankole.Workflow.touch_running_task_in_tx(repo, call, DateTime.utc_now(:microsecond))

  defp touch_workflow_progress_in_tx(_repo, _call, _journal), do: :ok

  @doc """
  Injects the pending input that `include?` selects, in queue order up to the
  first input that cannot join a running turn, and appends it to the model input.
  """
  @spec inject_pending(t(), (ActorEvent.t() -> as_boolean(term()))) ::
          {:ok, [ActorEvent.t()], t()} | {:error, term()}
  def inject_pending(run, include?) do
    events =
      open_events(run)
      |> Enum.filter(&(&1.id in run.pending_event_ids and include?.(&1)))
      |> Enum.take_while(&Ankole.Conversations.Commands.injectable?/1)

    with {:ok, injected} <- inject(run, events) do
      visible = AIGatewayLink.visible_channel_context_refs(run.agent_uid, run.session_id)
      ids = Enum.map(injected, & &1.id)

      {:ok, injected,
       %{
         run
         | input:
             run.input ++
               Enum.flat_map(injected, &Ankole.Conversations.Prompt.steer(run, &1, visible)),
           steer_event_ids: Enum.uniq(run.steer_event_ids ++ ids),
           pending_event_ids: run.pending_event_ids -- ids
       }}
    end
  end

  @spec inject(t(), [ActorEvent.t()], DateTime.t()) :: {:ok, [ActorEvent.t()]} | {:error, term()}
  def inject(run, events, now \\ DateTime.utc_now(:microsecond)) do
    Repo.transact(fn repo ->
      with :ok <- Fence.check_in_tx(repo, run) do
        events
        |> Enum.sort_by(& &1.queue_sequence)
        |> Enum.reduce_while({:ok, []}, fn event, {:ok, injected} ->
          case inject_event_in_tx(repo, run, event, now) do
            {:ok, nil} -> {:cont, {:ok, injected}}
            {:ok, current} -> {:cont, {:ok, [current | injected]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, events} -> {:ok, Enum.reverse(events)}
          error -> error
        end
      end
    end)
  end

  defp inject_event_in_tx(repo, run, event, now) do
    with %ActorEvent{agent_uid: uid, session_id: session, input_state: "open", completed_at: nil} =
           current <-
           Actors.lock_actor_event_in_tx(repo, event.id),
         true <- uid == run.agent_uid and session == run.session_id,
         {:ok, %ActorEvent{input_state: "open", completed_at: nil} = authorized} <-
           Ankole.Conversations.Admission.authorize_event_in_tx(repo, current) do
      authorized |> ActorEvent.changeset(%{last_attempt_at: now}) |> repo.update()
    else
      {:error, _} = error -> error
      _closed -> {:ok, nil}
    end
  end

  @spec finalize(t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def finalize(run, outcome \\ "loop_finished", reason \\ nil) do
    Repo.transact(fn repo -> finalize_in_tx(repo, run, outcome, reason) end)
    |> after_finalization()
  end

  def after_finalization(result) do
    case result do
      {:ok, %{run: run} = result} ->
        if result.journal,
          do: StatefulResponses.publish_tool_result_events(result.journal.message)

        Presentation.stop(run)
        {:ok, result}

      other ->
        other
    end
  end

  @spec finalize_recovered_in_tx(module(), t(), String.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def finalize_recovered_in_tx(repo, run, outcome, reason) do
    with :ok <- Fence.check_in_tx(repo, run),
         {:ok, _} <- end_model_in_tx(repo, run, "stopped", DateTime.utc_now(:microsecond)),
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
             %__MODULE__{
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
         outcome when outcome in ["sleeping", "submitted"] <- committed_workflow_outcome(run),
         {:ok, workspace} <-
           workspace |> Ecto.Changeset.change(epoch: workspace.epoch + 1) |> repo.update() do
      # The existing attempt ended before its input closed. A new claim would
      # change its committed domain state, including during tenant suspension.
      attempt = AIGateway.response_metadata(run.model_response)["loop"]["workflow_attempt"]
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
        %ToolResult{outcome: outcome} = result when outcome in ["sleeping", "submitted"] ->
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

  @spec reject_input_in_tx(module(), ActorEvent.t(), String.t(), term()) ::
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
          run = %__MODULE__{
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

  @spec finalize_in_tx(module(), t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def finalize_in_tx(repo, run, outcome, reason) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- Fence.check_in_tx(repo, run),
         {:ok, _} <- end_model_in_tx(repo, run, outcome, now),
         {:ok, {run, journal}} <- finish_pending_in_tx(repo, run),
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

  def record_pending_in_tx(repo, run), do: finish_pending_in_tx(repo, run)

  defp finish_pending_in_tx(_repo, %{calls: []} = run), do: {:ok, {run, nil}}

  defp finish_pending_in_tx(repo, run) do
    results =
      Map.new(run.calls, fn call ->
        id = call_id(call)

        result =
          case Receipts.fetch(response_id(run.model_response), id) do
            {:ok, receipt} ->
              case ToolResult.decode(receipt.result, receipt.inserted_at) do
                {:await, _wait} ->
                  Ankole.Conversations.Tools.result(%{"status" => "queued"},
                    text:
                      "The operation is committed. Observation was interrupted; do not resend it."
                  )

                result ->
                  result
              end

            {:error, :receipt_not_found} ->
              Map.get(run.results, id, Ankole.Conversations.Tools.interrupted())
          end

        {id, result}
      end)

    with {:ok, journal} <- record_round_in_tx(repo, %{run | results: results}) do
      {:ok, {%{run | calls: [], results: %{}, anchor: journal.message.id}, journal}}
    end
  end

  defp completion(_run, outcome)
       when outcome in ["stopped", "dead_letter", "silent", "sleeping", "submitted", "requeued"],
       do: {:ok, %{final_text: nil, clarify_prompt: nil, attachments: []}}

  defp completion(run, outcome) do
    with {:ok, completion} <- AIGatewayLink.load_turn_completion(run, external_anchor(run.anchor)),
         {:ok, completion} <-
           Ankole.Conversations.Scheduled.project_completion(
             run.event,
             completion,
             outcome
           ) do
      if is_binary(completion.final_text) or is_map(completion.clarify_prompt) or
           completion.attachments != [],
         do: {:ok, completion},
         else: {:error, :turn_completion_has_no_user_visible_projection}
    end
  end

  defp end_model_in_tx(repo, run, outcome, now) when outcome in ["stopped", "dead_letter"] do
    AIGatewayLink.retract_generating_turn_in_tx(repo, run, run.actor_event_id, now, outcome)
  end

  defp end_model_in_tx(_repo, _run, _outcome, _now), do: {:ok, nil}

  defp lock_applied_events(repo, run, outcome) do
    with {:ok, history} <- input_history(run) do
      injected =
        Enum.flat_map(
          history,
          &(AIGateway.response_metadata(&1)["loop"]["steer_event_ids"] || [])
        )

      ids =
        Enum.uniq(
          [run.actor_event_id | injected] ++
            if(outcome == "stopped", do: run.steer_event_ids, else: [])
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
         "dead_letter",
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
         "stopped",
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
      if outcome in ["stopped", "sleeping", "submitted", "requeued"], do: "silent", else: outcome

    with {:ok, outboxes} <-
           Presentation.commit_outboxes_in_tx(repo, reply_event, completion, visible_outcome, now),
         {:ok, _} <-
           update_events(events, fn event ->
             if outcome in ["stopped", "sleeping", "submitted", "requeued"],
               do: Actors.mark_event_completed_in_tx(repo, event, now),
               else:
                 Actors.mark_turn_event_completed_in_tx(
                   repo,
                   event,
                   now,
                   external_anchor(run.anchor),
                   outcome
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

  defp live_sources(_repo, _events, "stopped", _now), do: :ok

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

  def refund(run, mode) when mode in [:shutdown, :stale_driver] do
    Repo.transact(fn repo ->
      workspace =
        repo.one(
          from w in ActorSessionWorkspace,
            where: w.agent_uid == ^run.agent_uid and w.session_id == ^run.session_id,
            lock: "FOR UPDATE"
        )

      eligible? =
        workspace &&
          ((mode == :shutdown and workspace.epoch == run.epoch) or
             (mode == :stale_driver and workspace.epoch > run.epoch))

      with true <- eligible?,
           %ActorEvent{
             completed_at: nil,
             input_state: "open",
             attempt_count: count,
             provider_capacity_attempt_count: capacity
           } = event
           when count > capacity <- Actors.lock_actor_event_in_tx(repo, run.actor_event_id) do
        event |> ActorEvent.changeset(%{attempt_count: count - 1}) |> repo.update()
      else
        _ -> {:ok, :unchanged}
      end
    end)
  end

  @spec metadata(t()) :: map()
  def metadata(run) do
    %{
      "actor_event_id" => run.actor_event_id,
      "loop" => %{
        "iteration" => run.iteration,
        "steer_event_ids" => run.steer_event_ids,
        "nudged" => run.nudged,
        "repaired" => run.repaired,
        "repair_failure" => run.repair_failure,
        "workflow_attempt" =>
          if(run.kind == :workflow_task, do: run.spec.request_context["attempt"]),
        "truncated_rounds" => run.truncated_rounds,
        "outcome" => run.outcome,
        "pages" => run.pages
      }
    }
  end

  @spec executable_calls(map()) :: [map()]
  def executable_calls(message),
    do: message |> response_output() |> Enum.filter(&ResponseItems.executable_call?/1)

  @spec visible_delivery?(map(), ToolResult.t()) :: boolean()
  def visible_delivery?(call, result),
    do: result.is_error != true and call["name"] in ["clarify", "reply_attachment"]

  @spec tool_identity(t(), map()) :: String.t()
  def tool_identity(run, call), do: "#{response_id(run.model_response)}:#{call_id(call)}"

  @spec call_id(map()) :: String.t()
  def call_id(call), do: call[ResponseItems.pair_identity_field(call)]
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

  defp reclaim(run) do
    result =
      Repo.transact(fn repo ->
        with :ok <- Fence.check_in_tx(repo, run),
             {:ok, generating} <-
               AIGateway.list_conversation_responses_in_tx(
                 repo,
                 run.agent_uid,
                 run.conversation.id,
                 statuses: ["generating"],
                 lock: true
               ) do
          Enum.reduce_while(generating, {:ok, []}, fn message, {:ok, reclaimed} ->
            case AIGateway.reconcile_orphaned_response_in_tx(repo, response_id(message),
                   force: true
                 ) do
              {:ok, {:failed, failed, _error}} -> {:cont, {:ok, [failed | reclaimed]}}
              {:ok, :already_terminal} -> {:cont, {:ok, reclaimed}}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end
      end)

    case result do
      {:ok, reclaimed} ->
        Enum.each(reclaimed, &AIGatewayLink.publish_failed_response/1)
        {:ok, :reclaimed}

      error ->
        error
    end
  end

  defp restore_pages(rows),
    do:
      Enum.reduce(
        rows,
        %{},
        &Map.merge(&2, AIGateway.response_metadata(&1)["loop"]["pages"] || %{})
      )

  defp journal?(message), do: message.metadata["tool_result_journal"] == true

  defp journal_results(journal) do
    fields = AIGateway.response_metadata(journal)["loop"]["results"] || %{}

    Map.new(Enum.filter(journal.content, &ResponseItems.output_item?/1), fn item ->
      id = item[ResponseItems.pair_identity_field(item)]
      output = item["output"]

      details =
        case Ankole.JSON.decode(output || "") do
          {:ok, value} -> value
          _ -> %{}
        end

      {id,
       ToolResult.decode(
         Map.merge(fields[id] || %{}, %{"output" => output, "details" => details})
       )}
    end)
  end

  defp fold_tool_history(run, rows) do
    models = Map.new(Enum.reject(rows, &journal?/1), &{&1.id, &1})

    Enum.reduce(Enum.filter(rows, &journal?/1), run, fn journal, run ->
      calls =
        case models[journal.previous_message_id] do
          nil -> []
          model -> executable_calls(model)
        end

      results = journal_results(journal)

      Enum.reduce(calls, run, fn call, run ->
        result = results[call_id(call)]

        if result do
          run = restore_todo(run, call, result)

          follow_ups = run.follow_ups
          run = Ankole.Conversations.Machine.failure(run, call, result)

          %{
            run
            | follow_ups: follow_ups,
              visible_delivery?: run.visible_delivery? or visible_delivery?(call, result)
          }
        else
          run
        end
      end)
    end)
  end

  defp restore_todo(run, call, result) do
    if call["name"] == "todo" and result.is_error != true do
      with {:ok, args} <- Ankole.JSON.decode(call["arguments"] || ""),
           {:ok, result} <-
             Ankole.Conversations.Tools.Session.execute(
               run,
               call,
               Ankole.Conversations.Tools.Session.normalize("todo", args)
             ),
           do: elem(Ankole.Conversations.Tools.attach(run, result), 0),
           else: (_ -> run)
    else
      run
    end
  end

  defp publish_journal({:ok, journal} = result) do
    StatefulResponses.publish_tool_result_events(journal.message)
    result
  end

  defp publish_journal(error), do: error
end
