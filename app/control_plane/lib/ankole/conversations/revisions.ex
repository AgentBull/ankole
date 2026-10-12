defmodule Ankole.Conversations.Revisions do
  @moduledoc "Applies in-flight input revisions under the driver's current epoch."
  alias Ankole.Repo
  alias Ankole.Conversations.{Fence, Run, Presentation}
  alias Ankole.SignalsGateway.{ActorEvent, Actors, AIGatewayLink, AIReplyPreview}
  alias Ankole.SignalsGateway.InputRevisions

  def immediate?(run, event) do
    revision = get_in(event.payload, ["data", "revision"]) || %{}

    revision["actor_event_id"] in [run.actor_event_id | run.steer_event_ids] and
      (revision["kind"] == "remove" or not executable?(run))
  end

  def apply(run, event) do
    revision = get_in(event.payload, ["data", "revision"])
    now = DateTime.utc_now(:microsecond)
    keep_history? = executable?(run)

    Repo.transact(fn repo ->
      with :ok <- Fence.check_in_tx(repo, run),
           %ActorEvent{completed_at: nil, input_state: "open"} = target <-
             Actors.lock_actor_event_in_tx(repo, revision["actor_event_id"]),
           true <- target.agent_uid == run.agent_uid and target.session_id == run.session_id,
           {:ok, _} <-
             AIGatewayLink.retract_generating_turn_in_tx(
               repo,
               run,
               run.actor_event_id,
               now,
               "input_superseded"
             ),
           {:ok, {run, _journal}} <- Run.record_pending_in_tx(repo, run),
           {:ok, _} <- retract_suffix(repo, run, now, keep_history?),
           {:ok, updated} <-
             InputRevisions.revise_event_in_tx(
               repo,
               target,
               revision["kind"],
               revision["entry"],
               now
             ) do
        if updated == :removed and target.id == run.actor_event_id do
          complete_removed_trigger_inputs(repo, run, event, now)
        else
          apply_revision_input(repo, run, event, target, updated, now)
        end
      else
        false -> {:error, :revision_target_unavailable}
        nil -> {:error, :revision_target_unavailable}
        error -> error
      end
    end)
    |> then(fn result ->
      case result do
        {:ok, :stopped} -> Presentation.stop(run)
        {:ok, _} -> AIReplyPreview.input_superseded(run.event)
        _ -> :ok
      end

      result
    end)
  end

  defp apply_revision_input(repo, run, event, target, updated, now) do
    event = Actors.lock_actor_event_in_tx(repo, event.id)

    with {:ok, _} <- repo.update(ActorEvent.changeset(event, %{last_attempt_at: now})) do
      trigger = if target.id == run.actor_event_id, do: updated, else: run.event

      {:ok, %{Run.reset(run) | event: trigger, delivered_event: trigger}}
    end
  end

  defp complete_removed_trigger_inputs(repo, run, event, now) do
    # Deletion of the trigger also closes its applied revisions and steers.
    Enum.reduce_while(Enum.uniq([event.id | run.steer_event_ids]), {:ok, :stopped}, fn id, _ ->
      case Actors.lock_actor_event_in_tx(repo, id) do
        %ActorEvent{} = input ->
          case Actors.mark_event_completed_in_tx(repo, input, now) do
            {:ok, _} -> {:cont, {:ok, :stopped}}
            error -> {:halt, error}
          end

        nil ->
          {:cont, {:ok, :stopped}}
      end
    end)
  end

  defp retract_suffix(_repo, _run, _now, true), do: {:ok, nil}

  defp retract_suffix(repo, run, now, false) do
    AIGatewayLink.retract_visible_turn_suffix_in_tx(
      repo,
      run.agent_uid,
      run.session_id,
      run.actor_event_id,
      now,
      reason: "input_superseded"
    )
  end

  defp executable?(run), do: run.saw_tool_results or run.round_calls != []
end
