defmodule Ankole.Sessions.Revisions do
  @moduledoc "Applies in-flight input revisions under the driver's current epoch."
  import Ash.Expr, only: [expr: 1]
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Presentation
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.MessageInput
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.Delivery.Preview

  def immediate?(
        run,
        %Signal{producer: :kernel, last_attempt_at: nil, data: %{"revision" => revision}} = event
      )
      when is_map(revision) do
    event.agent_uid == run.agent_uid and event.session_id == run.session_id and
      revision["signal_id"] in [run.signal_id | run.steer_event_ids] and
      revision["kind"] in ["edit", "remove", "supplement"] and
      (revision["kind"] == "remove" or not executable?(run))
  end

  def immediate?(_run, _event), do: false

  def apply(run, %Signal{producer: :kernel, data: %{"revision" => revision}} = event)
      when is_map(revision) do
    now = DateTime.utc_now(:microsecond)

    Ankole.Repo.transact_top_level(fn -> apply_in_tx(run, event, now) end)
    |> Ankole.Errors.reason()
    |> then(fn result ->
      case result do
        {:ok, :stopped} -> Presentation.stop(run)
        {:ok, _} -> Preview.input_superseded(run.event)
        _ -> :ok
      end

      result
    end)
  end

  def apply(_run, _event), do: {:error, :revision_target_unavailable}

  @doc false
  def apply_in_tx(run, %Signal{data: %{"revision" => revision}} = event, now) do
    keep_history? = executable?(run)

    with :ok <- Fence.check_in_tx(run),
         {:ok, event} <- mark_revision_inputs_in_tx(event, now),
         %Signal{status: live_status} = target when live_status in [:queued, :running] <-
           Ankole.Signals.lock_signal_in_tx(revision["signal_id"]),
         true <- target.agent_uid == run.agent_uid and target.session_id == run.session_id,
         {:ok, _} <-
           ModelHistory.retract_generating_turn_in_tx(
             run,
             run.signal_id,
             now,
             "input_superseded"
           ),
         {:ok, {run, _journal}} <- Run.record_pending_in_tx(run),
         {:ok, _} <- retract_suffix(run, now, keep_history?),
         {:ok, updated} <- revise_input_in_tx(target, revision, now) do
      if updated == :removed and target.id == run.signal_id do
        complete_removed_trigger_inputs(run, event, now)
      else
        apply_revision_input(run, event, target, updated)
      end
    else
      false -> {:error, :revision_target_unavailable}
      nil -> {:error, :revision_target_unavailable}
      error -> error
    end
  end

  defp revise_input_in_tx(target, revision, now),
    do: revise_event_in_tx(target, revision["kind"], revision["entry"], now)

  def revise_event_in_tx(event, kind, entry, now) do
    case MessageInput.revised_input_attrs(event, kind, entry, now) do
      :no_match ->
        {:ok, event}

      :cancel ->
        with {:ok, _} <- Ankole.Conversations.Delivery.Deletion.commit_source_in_tx(event),
             :ok <- Ankole.Signals.remove_signal(event),
             do: {:ok, :removed}

      {:update, attrs} ->
        Ankole.Signals.revise_input_signal(event, attrs)
    end
  end

  defp mark_revision_inputs_in_tx(event, now),
    do: Ankole.Signals.transition_in_tx(event, :start_attempt, %{last_attempt_at: now})

  defp apply_revision_input(run, event, target, updated) do
    trigger = if target.id == run.signal_id, do: updated, else: run.event

    ids =
      [
        query: [
          filter:
            expr(
              agent_uid == ^run.agent_uid and session_id == ^run.session_id and
                type == "input.revised" and producer == :kernel and
                status in [:queued, :running] and not is_nil(last_attempt_at) and
                fragment("? #>> '{revision,signal_id}'", data) == ^run.signal_id
            ),
          select: [:id]
        ]
      ]
      |> Ankole.Signals.list_signals!()
      |> Enum.map(& &1.id)

    {:ok,
     %{
       Run.reset(run)
       | event: trigger,
         delivered_event: trigger,
         steer_event_ids: Enum.uniq(run.steer_event_ids ++ ids ++ [event.id])
     }}
  end

  defp complete_removed_trigger_inputs(run, event, now) do
    # Deletion of the trigger also closes its applied revisions and steers.
    Enum.reduce_while(Enum.uniq([event.id | run.steer_event_ids]), {:ok, :stopped}, fn id, _ ->
      case Ankole.Signals.lock_signal_in_tx(id) do
        %Signal{} = input ->
          case Queue.mark_event_completed_in_tx(input, now) do
            {:ok, _} -> {:cont, {:ok, :stopped}}
            error -> {:halt, error}
          end

        nil ->
          {:cont, {:ok, :stopped}}
      end
    end)
  end

  defp retract_suffix(_run, _now, true), do: {:ok, nil}

  defp retract_suffix(run, now, false) do
    ModelHistory.retract_visible_turn_suffix_in_tx(
      run.agent_uid,
      run.session_id,
      run.signal_id,
      now,
      reason: "input_superseded"
    )
  end

  defp executable?(run), do: run.saw_tool_results or run.round_calls != []
end
