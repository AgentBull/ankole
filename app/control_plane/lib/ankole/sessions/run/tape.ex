defmodule Ankole.Sessions.Run.Tape do
  @moduledoc """
  Restores a Session Run from its durable response tape and records completed
  tool-result rounds onto that tape.
  """

  require Ash.Query

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolResultJournal
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.Receipt
  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.RoundState
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.ToolResult
  alias Ankole.Signals.Signal

  @spec restore(Run.t()) :: {:ok, {atom(), Run.t()}} | {:error, term()}
  def restore(%{__struct__: Run} = run) do
    with {:ok, _reclaimed} <-
           Ankole.Repo.transact_top_level(
             fn -> reclaim_in_tx(run) end,
             after_commit: {__MODULE__, :publish_reclaimed}
           )
           |> Ankole.Errors.reason(),
         do: restore_receipts(run)
  end

  @doc "Restores a run inside the caller's transaction. See `restore/1`."
  def restore_in_tx(%{__struct__: Run} = run) do
    with {:ok, reclaimed} <- reclaim_in_tx(run) do
      publish_reclaimed(reclaimed)
      restore_receipts(run)
    end
  end

  defp restore_receipts(run) do
    with {:ok, {state, run}} <- restore_tape(run) do
      receipts =
        if state == :executing_tools do
          response_id = Run.response_id(run.model_response)

          Receipt
          |> Ash.Query.filter(response_id == ^response_id)
          |> Ankole.Ash.read!()
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
    with {:ok, tail} <-
           AIGateway.visible_response_suffix(
             run.agent_uid,
             run.conversation.id,
             {"signal_id", run.signal_id}
           ) do
      latest = List.last(tail.responses)
      states = RoundState.load(tail.rows)
      loop = RoundState.for_message(states, latest)

      steers =
        tail.responses
        |> taped_steer_event_ids(states)
        |> retained_event_ids()

      round_calls = if latest, do: Run.executable_calls(latest), else: []

      calls =
        if latest && not Run.truncated?(latest),
          do: Enum.reject(round_calls, &MapSet.member?(tail.recorded_call_ids, Run.call_id(&1))),
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
          pages: restore_pages(tail.rows, states),
          steer_event_ids: steers,
          calls: calls,
          round_calls: round_calls,
          results: results,
          saw_tool_results: Enum.any?(tail.rows, &journal?/1),
          recovered?: latest != nil,
          pending_event_ids:
            Queue.due(run)
            |> Enum.reject(&(&1.id == run.signal_id or &1.id in steers))
            |> Enum.map(& &1.id)
      }

      run = run |> RoundState.restore(loop) |> fold_tool_history(tail.rows, states)

      run =
        if restore_attempt? and run.kind == :workflow_task,
          do: Ankole.Sessions.WorkflowTask.restore_attempt(run, latest, loop),
          else: run

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
      [query: [filter: [id: [in: ids]], select: [:id]]]
      |> Ankole.Signals.list_signals!()
      |> MapSet.new(& &1.id)

    Enum.filter(ids, &MapSet.member?(retained, &1))
  end

  @doc false
  def taped_steer_event_ids(responses, states) do
    responses
    |> Enum.flat_map(&RoundState.for_message(states, &1).steer_event_ids)
    |> Enum.uniq()
  end

  @spec record_round(Run.t()) :: {:ok, map()} | {:error, term()}
  def record_round(run) do
    # Images that follow tool results enter history without a model request, so
    # they get the model's image rule here, before the transaction: history
    # keeps what the model sees, as it does for received images.
    follow_ups =
      AIGateway.adapt_images(
        run.agent_uid,
        run.follow_ups,
        Ankole.Sessions.Model.vision(run.spec.model_ref),
        subject_type: "agent",
        request_context: run.spec.request_context
      )

    round_run = %{run | follow_ups: follow_ups}

    Ankole.Repo.transact_top_level(
      fn -> record_round_in_tx(round_run) end,
      after_commit: {__MODULE__, :publish_journal}
    )
    |> Ankole.Errors.reason()
  end

  @spec record_round_in_tx(Run.t()) :: {:ok, map()} | {:error, term()}
  def record_round_in_tx(run) do
    with {:ok, workflow_call} <- lock_workflow_progress_in_tx(run),
         :ok <- Queue.lock_session_in_tx(run.agent_uid, run.session_id),
         :ok <- Fence.check_in_tx(run),
         {:ok, journal} <-
           record_tool_results_and_complete_events_in_tx(
             run.agent_uid,
             run.signal_id,
             run.wait_event_ids,
             %{
               "previous_response_id" => run.model_response.id,
               "input" =>
                 Enum.map(
                   run.calls,
                   &Run.output(&1, Map.fetch!(run.results, Run.call_id(&1)))
                 ) ++ run.follow_ups,
               "metadata" => Run.metadata(run)
             }
           ),
         :ok <- RoundState.put_in_tx(run, journal.message, run.results),
         :ok <- touch_workflow_progress_in_tx(workflow_call, journal) do
      Receipts.delete_round_in_tx(run, Run.response_id(run.model_response))
      {:ok, journal}
    end
  end

  def record_pending_in_tx(%{calls: []} = run), do: {:ok, {run, nil}}

  def record_pending_in_tx(run) do
    results =
      Map.new(run.calls, fn call ->
        id = Run.call_id(call)

        result =
          case Receipts.fetch(Run.response_id(run.model_response), id) do
            {:ok, receipt} ->
              case ToolResult.decode(receipt.result, receipt.inserted_at) do
                {:await, _wait} ->
                  Ankole.Sessions.Tools.result(%{"status" => "queued"},
                    text:
                      "The operation is committed. Observation was interrupted; do not resend it."
                  )

                result ->
                  result
              end

            {:error, :receipt_not_found} ->
              Map.get(run.results, id, Ankole.Sessions.Tools.interrupted())
          end

        {id, result}
      end)

    with {:ok, journal} <- record_round_in_tx(%{run | results: results}) do
      {:ok, {%{run | calls: [], results: %{}, anchor: journal.message.id}, journal}}
    end
  end

  defp record_tool_results_and_complete_events_in_tx(
         subject_uid,
         current_event_id,
         event_ids,
         request
       ) do
    with %Signal{} = current_event <- Ankole.Signals.get_signal!(current_event_id),
         :ok <-
           Queue.lock_session_in_tx(
             current_event.agent_uid,
             current_event.session_id
           ),
         %Signal{} <- Ankole.Signals.lock_signal_in_tx(current_event_id),
         {:ok, target_events} <- lock_target_events(event_ids),
         {:ok, journal} <-
           AIGateway.record_tool_results_in_tx(
             subject_uid,
             request,
             %{"completed_signal_ids" => event_ids}
           ),
         :ok <- complete_target_events(target_events, journal.disposition) do
      {:ok, journal}
    else
      nil -> {:error, :signal_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp lock_target_events(event_ids) do
    events = Enum.map(event_ids, &Ankole.Signals.lock_signal_in_tx(&1))

    if Enum.all?(events, &match?(%Signal{}, &1)),
      do: {:ok, events},
      else: {:error, :signal_not_found}
  end

  defp complete_target_events(events, :inserted) do
    now = DateTime.utc_now(:microsecond)

    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Queue.mark_event_completed_in_tx(event, now) do
        {:ok, %Signal{}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp complete_target_events(_events, :existing), do: :ok

  defp lock_workflow_progress_in_tx(%{kind: :workflow_task} = run),
    do: Ankole.Sessions.WorkflowTask.lock_progress_in_tx(run)

  defp lock_workflow_progress_in_tx(_run), do: {:ok, nil}

  defp touch_workflow_progress_in_tx(call, %{disposition: :inserted}),
    do:
      Ankole.Workflow.TaskLifecycle.touch_running_task_in_tx(
        call,
        DateTime.utc_now(:microsecond)
      )

  defp touch_workflow_progress_in_tx(_call, _journal), do: :ok

  @doc false
  def reclaim_in_tx(run) do
    with :ok <- Fence.check_in_tx(run),
         {:ok, generating} <-
           AIGateway.list_conversation_responses_in_tx(
             run.agent_uid,
             run.conversation.id,
             statuses: [:generating],
             lock: true
           ) do
      Enum.reduce_while(generating, {:ok, []}, fn message, {:ok, reclaimed} ->
        case AIGateway.reconcile_orphaned_response_in_tx(
               Run.response_id(message),
               force: true
             ) do
          {:ok, {:failed, failed, _error}} -> {:cont, {:ok, [failed | reclaimed]}}
          {:ok, :already_terminal} -> {:cont, {:ok, reclaimed}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Publishes the responses that a committed reclaim failed."
  def publish_reclaimed(reclaimed),
    do: Enum.each(reclaimed, &ModelHistory.publish_failed_response/1)

  @doc "Publishes the tool result events of a committed journal."
  def publish_journal(journal), do: ToolResultJournal.publish_tool_result_events(journal.message)

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
          model -> Run.executable_calls(model)
        end

      results = journal_results(journal, RoundState.for_message(states, journal))

      Enum.reduce(calls, run, fn call, run ->
        result = results[Run.call_id(call)]

        if result do
          run = %{run | todo: result.todos || run.todo}

          follow_ups = run.follow_ups
          run = Ankole.Sessions.Turn.track_failure(run, call, result)

          %{
            run
            | follow_ups: follow_ups,
              visible_delivery?: run.visible_delivery? or Run.visible_delivery?(run, call, result)
          }
        else
          run
        end
      end)
    end)
  end
end
