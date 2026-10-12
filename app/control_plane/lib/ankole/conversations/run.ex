defmodule Ankole.Conversations.Run do
  alias Ankole.AIGateway.ToolResultJournal

  @moduledoc """
  Rebuilds one run from its inbox and tape and commits driver decisions.

  The workspace epoch serializes these decisions with tool transactions.
  A process contains no authoritative progress that must survive its exit.
  """

  import Ecto.Query

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.Conversations.RoundState
  alias Ankole.Conversations.Fence
  alias Ankole.Conversations.Receipts
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
  def type(%ActorEvent{} = event), do: event |> kind() |> type()
  def type(:main), do: Ankole.Conversations.Main
  def type(:ambient), do: Ankole.Conversations.Ambient
  def type(:scheduled), do: Ankole.Conversations.Scheduled
  def type(:workflow_task), do: Ankole.Conversations.WorkflowTask

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

    with :ok <- Fence.check_in_tx(repo, run),
         %ActorEvent{} = event <- Actors.lock_actor_event_in_tx(repo, run.actor_event_id) do
      if event.available_at != run.event.available_at do
        {:ok, event}
      else
        count = event.provider_capacity_attempt_count + if(capacity?, do: 1, else: 0)
        attempt = if capacity?, do: count, else: event.attempt_count - count
        class = if capacity?, do: :provider_capacity, else: :execution

        due =
          Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifier.credential_pool_retry_at(
            error,
            now
          ) || DateTime.add(now, backoff_seconds(attempt, class))

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

  def backoff_seconds(attempt, class),
    do:
      Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifier.delay_seconds(
        :conversation,
        attempt,
        class
      )

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

  @doc false
  def restore_tape(run, restore_attempt? \\ true) do
    with {:ok, tail} <- AIGateway.conversation_tail(run.conversation, run.actor_event_id) do
      latest = List.last(tail.responses)
      states = RoundState.load(tail.rows)
      loop = RoundState.for_message(states, latest)

      steers =
        tail.responses
        |> Enum.flat_map(&RoundState.for_message(states, &1).steer_event_ids)
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

      results =
        if latest_journal,
          do: journal_results(latest_journal, RoundState.for_message(states, latest_journal)),
          else: %{}

      run = %{
        run
        | model_response: latest,
          anchor: tail.leaf,
          iteration: loop.iteration || 0,
          nudged: loop.nudged || false,
          repaired: loop.repaired || false,
          repair_failure: loop.repair_failure,
          truncated_rounds: loop.truncated_rounds || 0,
          outcome: loop.outcome || :loop_finished,
          pages: restore_pages(tail.rows, states),
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

      run = fold_tool_history(run, tail.rows, states)

      run = if restore_attempt?, do: type(run).restore_attempt(run, latest, loop), else: run

      state =
        cond do
          is_nil(run.model_response) -> :preparing
          run.calls != [] -> :executing_tools
          true -> :boundary
        end

      {:ok, {state, run}}
    end
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
         {:ok, workflow_call} <- type(run).lock_progress_in_tx(repo, run),
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
               "metadata" => metadata(run)
             }
           ),
         :ok <- RoundState.put_in_tx(repo, run, journal.message, run.results),
         :ok <- touch_workflow_progress_in_tx(repo, workflow_call, journal) do
      Receipts.delete_round_in_tx(repo, run, response_id(run.model_response))
      {:ok, journal}
    end
  end

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

  defdelegate finalize(run, outcome \\ :loop_finished, reason \\ nil),
    to: Ankole.Conversations.Completion

  defdelegate after_finalization(result), to: Ankole.Conversations.Completion

  defdelegate finalize_recovered_in_tx(repo, run, outcome, reason),
    to: Ankole.Conversations.Completion

  defdelegate finalize_committed_workflow_input_in_tx(repo, event),
    to: Ankole.Conversations.Completion

  defdelegate reject_input_in_tx(repo, event, outcome, reason),
    to: Ankole.Conversations.Completion

  defdelegate finalize_in_tx(repo, run, outcome, reason), to: Ankole.Conversations.Completion

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
  def metadata(run), do: %{"actor_event_id" => run.actor_event_id}

  @spec executable_calls(map()) :: [map()]
  def executable_calls(message) do
    message
    |> response_output()
    |> Enum.filter(&(ResponseItems.client_call_item?(&1) and ResponseItems.executable_call?(&1)))
  end

  @spec visible_delivery?(t(), map(), ToolResult.t()) :: boolean()
  def visible_delivery?(run, call, result) do
    tool = Ankole.Conversations.ToolCatalog.find(run, call)
    result.is_error != true and tool != nil and tool.visible_delivery
  end

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

  defp restore_pages(rows, states),
    do: Enum.reduce(rows, %{}, &Map.merge(&2, RoundState.for_message(states, &1).pages))

  defp journal?(message), do: message.metadata["tool_result_journal"] == true

  defp journal_results(journal, state) do
    fields = state.results

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

  defp fold_tool_history(run, rows, states) do
    models = Map.new(Enum.reject(rows, &journal?/1), &{&1.id, &1})

    Enum.reduce(Enum.filter(rows, &journal?/1), run, fn journal, run ->
      calls =
        case models[journal.previous_message_id] do
          nil -> []
          model -> executable_calls(model)
        end

      results = journal_results(journal, RoundState.for_message(states, journal))

      Enum.reduce(calls, run, fn call, run ->
        result = results[call_id(call)]

        if result do
          run = %{run | todo: result.todos || run.todo}

          follow_ups = run.follow_ups
          run = Ankole.Conversations.Machine.failure(run, call, result)

          %{
            run
            | follow_ups: follow_ups,
              visible_delivery?: run.visible_delivery? or visible_delivery?(run, call, result)
          }
        else
          run
        end
      end)
    end)
  end

  defp publish_journal({:ok, journal} = result) do
    ToolResultJournal.publish_tool_result_events(journal.message)
    result
  end

  defp publish_journal(error), do: error
end
