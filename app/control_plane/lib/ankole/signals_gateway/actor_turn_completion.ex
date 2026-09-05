defmodule Ankole.SignalsGateway.ActorTurnCompletion do
  @moduledoc """
  Commits one explicit Agent Computer turn completion into SignalsGateway.

  A terminal LLM Response is only immutable input to this operation. The
  worker's completion RPC is the declaration that the Agent loop has ended.
  This module then validates runtime fences and atomically commits provider
  outbox intents plus ActorEvent consumption.

  A `silent` completion consumes the same applied input prefix without a
  provider-visible reply. It records the outcome and, when the worker adopted
  a Response chain, the final Response ID, so a finished turn stays
  distinguishable from one that never ran.
  """

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Logging
  alias Ankole.Observability
  alias Ankole.Repo
  alias Ankole.Schedule.Delivery
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.ReplyInteractions
  alias Ankole.BackgroundAgentJobs

  @spec handle(TurnRef.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle(%TurnRef{} = turn_ref, final_response_id, outcome, opts) when is_list(opts) do
    with {:ok, outcome} <- completion_outcome(outcome),
         {:ok, final_response_id} <- completion_response_id(final_response_id, outcome) do
      case completed_actor_event(turn_ref) do
        %ActorEvent{} = event ->
          with :ok <- validate_completion_anchor(event, final_response_id, outcome) do
            {:ok, %{status: :already_completed, actor_event: event, outcome: outcome}}
            |> after_commit(turn_ref, final_response_id, outcome, nil)
          end

        nil ->
          with {:ok, completion} <- load_completion(turn_ref, final_response_id, outcome) do
            now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

            Repo.transact(fn repo ->
              commit_in_tx(repo, turn_ref, completion, outcome, now)
            end)
            |> after_commit(turn_ref, final_response_id, outcome, completion.final_text)
          end
      end
    end
  end

  # A silent turn projects no reply. When the worker adopted a Response, that
  # chain still has to belong to this turn and end in success.
  defp load_completion(turn_ref, final_response_id, "silent") do
    with :ok <- validate_silent_response(turn_ref, final_response_id) do
      {:ok, %{final_response_id: final_response_id, final_text: nil}}
    end
  end

  defp load_completion(turn_ref, final_response_id, _outcome) do
    with {:ok, completion} <- AIGatewayLink.load_turn_completion(turn_ref, final_response_id) do
      {:ok, Map.put(completion, :final_response_id, final_response_id)}
    end
  end

  defp validate_silent_response(_turn_ref, nil), do: :ok

  defp validate_silent_response(turn_ref, final_response_id) do
    with {:ok, _turn_chain} <- AIGatewayLink.load_turn_chain(turn_ref, final_response_id) do
      :ok
    end
  end

  defp completed_actor_event(turn_ref) do
    ActorEvent
    |> where([event], event.id == ^turn_ref.actor_event_id)
    |> where([event], event.agent_uid == ^turn_ref.agent_uid)
    |> where([event], event.session_id == ^turn_ref.session_id)
    |> where([event], not is_nil(event.completed_at))
    |> Repo.one()
  end

  defp commit_in_tx(repo, turn_ref, completion, outcome, now) do
    rows = TurnRef.lookup(repo, turn_ref)

    case lock_actor_event(repo, turn_ref) do
      %ActorEvent{completed_at: %DateTime{}} = event ->
        with :ok <- validate_completion_anchor(event, completion.final_response_id, outcome) do
          {:ok, %{status: :already_completed, actor_event: event, outcome: outcome}}
        end

      %ActorEvent{} = event ->
        rows = %{rows | deliveries: TurnRef.lock_live_deliveries(repo, turn_ref)}

        with :ok <- TurnRef.match(rows, turn_ref, :complete, now: now) do
          case Actors.ensure_event_source_live_in_tx(repo, event, now) do
            :ok ->
              commit_live_source_in_tx(
                repo,
                event,
                rows.activation,
                rows.deliveries,
                turn_ref,
                completion,
                outcome,
                now
              )

            {:error, :actor_event_canceled} ->
              cancel_tombstoned_source_in_tx(
                repo,
                event,
                rows.activation,
                rows.deliveries,
                turn_ref,
                completion,
                outcome,
                now
              )
          end
        end

      nil ->
        {:error, :actor_runtime_fence_not_found}
    end
  end

  defp commit_live_source_in_tx(
         repo,
         event,
         activation,
         deliveries,
         turn_ref,
         completion,
         outcome,
         now
       ) do
    with %ActorEvent{} = reply_event <-
           applied_reply_event(repo, event, deliveries, turn_ref),
         {:ok, outboxes} <- commit_outboxes(repo, reply_event, completion, outcome, now),
         {:ok, completed_events} <-
           complete_accepted_events(repo, event, deliveries, turn_ref, completion, outcome, now),
         {deleted_count, superseded_count} <-
           cleanup_deliveries(repo, turn_ref.actor_event_id, now),
         {:ok, activation} <- release_turn_in_tx(repo, turn_ref, activation, now) do
      {:ok,
       %{
         status: :turn_completed,
         outcome: outcome,
         actor_event: completed_main_event(completed_events, event),
         reply_actor_event: reply_event,
         activation: activation,
         completed_actor_events: completed_events,
         outboxes: outboxes,
         deleted_deliveries: deleted_count,
         superseded_deliveries: superseded_count
       }}
    end
  end

  defp applied_reply_event(repo, main_event, deliveries, turn_ref) do
    deliveries
    |> Enum.filter(&ActorEventDelivery.applied_by_worker?(&1, turn_ref.revision))
    |> Enum.sort_by(&{&1.revision, &1.queue_sequence}, :desc)
    |> Enum.find_value(main_event, fn delivery ->
      case Actors.lock_actor_event_in_tx(repo, delivery.actor_event_id) do
        %ActorEvent{} = event ->
          if AIReplyPreview.channel_reply_eligible?(event), do: event

        nil ->
          nil
      end
    end)
  end

  defp cancel_tombstoned_source_in_tx(
         repo,
         event,
         activation,
         deliveries,
         turn_ref,
         completion,
         outcome,
         now
       ) do
    with {:ok, completed_events} <-
           mark_accepted_events_completed(
             repo,
             event,
             deliveries,
             turn_ref,
             completion,
             outcome,
             now
           ),
         {deleted_count, superseded_count} <-
           cleanup_deliveries(repo, turn_ref.actor_event_id, now),
         {:ok, activation} <- release_turn_in_tx(repo, turn_ref, activation, now) do
      {:ok,
       %{
         status: :turn_canceled,
         reason: :actor_event_canceled,
         outcome: outcome,
         actor_event: completed_main_event(completed_events, event),
         activation: activation,
         completed_actor_events: completed_events,
         outboxes: %{attachments: [], clarify: nil, finals: []},
         deleted_deliveries: deleted_count,
         superseded_deliveries: superseded_count
       }}
    end
  end

  # The Session stays briefly on its worker for follow-up work. A finished
  # BackgroundAgentJob releases that worker slot in the same commit; every other
  # Session keeps its assignment.
  defp release_turn_in_tx(repo, turn_ref, activation, now) do
    with :ok <- BackgroundAgentJobs.finalize_worker_turn_in_tx(repo, turn_ref, now) do
      TurnLifecycle.mark_activation_idle_in_tx(repo, activation, now)
    end
  end

  defp lock_actor_event(repo, turn_ref) do
    ActorEvent
    |> where([event], event.id == ^turn_ref.actor_event_id)
    |> where([event], event.agent_uid == ^turn_ref.agent_uid)
    |> where([event], event.session_id == ^turn_ref.session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp commit_outboxes(_repo, _event, _completion, "silent", _now), do: {:ok, no_outboxes()}

  defp commit_outboxes(repo, event, completion, outcome, now) do
    if AIReplyPreview.channel_reply_eligible?(event) do
      case commit_reply_outboxes(repo, event, completion, outcome, now) do
        {:ok, outboxes} -> {:ok, outboxes}
        {:error, reason} -> skip_unroutable_reply(event, reason)
      end
    else
      {:ok, no_outboxes()}
    end
  end

  # The channel accepts no replies, or its route rows are deleted. The Turn's
  # work already happened and its answer is already in the transcript, so the
  # Turn completes and no impossible provider intent is stored. Failing here
  # would retry the whole Turn, and every retry costs another model call while
  # the route stays exactly as unreachable.
  #
  # A single default reply checks its one route before any outbox row is written,
  # so it reaches this branch. A cron target resolves its own route too, but
  # records an unreachable one as a terminal `:unsupported` row instead, because
  # one unavailable target must not cancel the others.
  defp skip_unroutable_reply(%ActorEvent{} = event, reason) do
    if Outbox.unroutable_reply_reason?(reason) do
      Logging.warning(
        "signals_gateway.actor_turn_completion.reply_route_unroutable",
        "actor turn completed without a reachable reply route",
        %{
          actor_event_id: event.id,
          agent_uid: event.agent_uid,
          binding_name: event.binding_name,
          signal_channel_id: event.signal_channel_id,
          reason: inspect(reason, limit: 20)
        }
      )

      {:ok, no_outboxes()}
    else
      {:error, reason}
    end
  end

  defp no_outboxes, do: %{attachments: [], clarify: nil, finals: []}

  defp commit_reply_outboxes(repo, event, completion, outcome, now) do
    opts = [turn_completion_outcome: outcome, delivery_targets: delivery_targets(event)]

    with {:ok, attachments} <-
           Outbox.commit_reply_attachment_outboxes_in_tx(
             repo,
             event,
             completion.final_response.id,
             completion.attachments,
             opts
           ),
         {:ok, clarify} <- commit_clarify_outbox(repo, event, completion, opts, now),
         {:ok, finals} <- commit_final_outboxes(repo, event, completion, opts) do
      {:ok, %{attachments: attachments, clarify: clarify, finals: finals}}
    end
  end

  defp commit_clarify_outbox(_repo, _event, %{clarify_prompt: nil}, _opts, _now),
    do: {:ok, nil}

  defp commit_clarify_outbox(repo, event, completion, opts, now) do
    if AIReplyPreview.channel_reply_eligible?(event) do
      %{"fallback_visible_text" => fallback, "interactive_output" => interactive_output} =
        completion.clarify_prompt

      text = join_clarify_text(completion.final_text, fallback)

      with {:ok, outbox} <-
             Outbox.commit_clarify_reply_outbox_in_tx(
               repo,
               event,
               completion.final_response,
               text,
               interactive_output,
               opts
             ),
           {:ok, _event} <-
             ReplyInteractions.open_in_tx(
               repo,
               event,
               outbox.payload["reply_presentation"],
               now
             ) do
        {:ok, outbox}
      end
    else
      {:ok, nil}
    end
  end

  defp commit_final_outboxes(repo, event, completion, opts) do
    if AIReplyPreview.channel_reply_eligible?(event) and is_nil(completion.clarify_prompt) and
         is_binary(completion.final_text) do
      Outbox.commit_final_reply_outboxes_in_tx(
        repo,
        event,
        completion.final_response,
        completion.final_text,
        Keyword.put(opts, :attachment_count, length(completion.attachments))
      )
    else
      {:ok, []}
    end
  end

  defp delivery_targets(%ActorEvent{} = event) do
    case ActorEvent.scheduled_delivery_snapshot(event) do
      %{} = delivery -> normalized_delivery_targets(event, delivery)
      _missing -> [default_delivery_target(event)]
    end
  end

  defp normalized_delivery_targets(event, delivery) do
    case Delivery.targets(delivery, event.binding_name) do
      {:ok, targets} ->
        targets
        |> Enum.with_index()
        |> Enum.map(fn {target, index} ->
          %{
            binding_name: target["binding_name"],
            signal_channel_id: target["signal_channel_id"],
            provider_thread_id: target["provider_thread_id"],
            primary: index == 0,
            key: Delivery.target_key(target)
          }
        end)

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.actor_turn_completion.scheduled_delivery_invalid",
          "scheduled work completed with an invalid delivery snapshot",
          %{
            actor_event_id: event.id,
            agent_uid: event.agent_uid,
            actor_event_type: event.type,
            reason: inspect(reason, limit: 20)
          }
        )

        [default_delivery_target(event)]
    end
  end

  defp default_delivery_target(event) do
    %{
      binding_name: event.binding_name,
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      primary: true,
      key: nil
    }
  end

  defp join_clarify_text(nil, fallback), do: fallback
  defp join_clarify_text("", fallback), do: fallback
  defp join_clarify_text(text, fallback), do: text <> "\n\n" <> fallback

  defp complete_accepted_events(repo, main_event, deliveries, turn_ref, completion, outcome, now) do
    complete_event_ids(
      repo,
      completion_event_ids(main_event, deliveries, turn_ref),
      main_event.id,
      completion_anchor(completion, outcome),
      now,
      :guard_source
    )
  end

  defp mark_accepted_events_completed(
         repo,
         main_event,
         deliveries,
         turn_ref,
         completion,
         outcome,
         now
       ) do
    complete_event_ids(
      repo,
      completion_event_ids(main_event, deliveries, turn_ref),
      main_event.id,
      completion_anchor(completion, outcome),
      now,
      :skip_source
    )
  end

  defp completion_event_ids(main_event, deliveries, turn_ref) do
    accepted_event_ids =
      deliveries
      |> Enum.filter(&ActorEventDelivery.applied_by_worker?(&1, turn_ref.revision))
      |> Enum.map(& &1.actor_event_id)
      |> Enum.uniq()

    Enum.uniq([main_event.id | accepted_event_ids])
  end

  defp complete_event_ids(repo, event_ids, main_event_id, anchor, now, source_mode) do
    Enum.reduce_while(event_ids, {:ok, []}, fn event_id, {:ok, completed} ->
      case Actors.lock_actor_event_in_tx(repo, event_id) do
        %ActorEvent{completed_at: nil} = event ->
          event_anchor = if event.id == main_event_id, do: anchor, else: %{}

          case complete_event(repo, event, now, source_mode, event_anchor) do
            {:ok, event} -> {:cont, {:ok, [event | completed]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        %ActorEvent{} = event ->
          {:cont, {:ok, [event | completed]}}

        nil ->
          {:cont, {:ok, completed}}
      end
    end)
    |> case do
      {:ok, completed} -> {:ok, Enum.reverse(completed)}
      {:error, _reason} = error -> error
    end
  end

  defp complete_event(repo, event, now, :guard_source, anchor),
    do:
      Actors.complete_actor_event_in_tx(
        repo,
        event,
        [completed_at: now] ++ Map.to_list(anchor)
      )

  defp complete_event(repo, event, now, :skip_source, anchor) when map_size(anchor) == 0,
    do: Actors.mark_event_completed_in_tx(repo, event, now)

  defp complete_event(repo, event, now, :skip_source, anchor) do
    Actors.mark_turn_event_completed_in_tx(
      repo,
      event,
      now,
      Map.fetch!(anchor, :final_response_id),
      Map.fetch!(anchor, :turn_outcome)
    )
  end

  defp completed_main_event(completed_events, fallback) do
    Enum.find(completed_events, fallback, &(&1.id == fallback.id))
  end

  defp cleanup_deliveries(repo, actor_event_id, now) do
    {deleted_count, _rows} =
      ActorEventDelivery
      |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
      |> where([delivery], delivery.state == "accepted")
      |> repo.delete_all()

    {superseded_count, _rows} =
      ActorEventDelivery
      |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
      |> where([delivery], delivery.state in ["created", "sent"])
      |> repo.update_all(
        set: [
          state: "superseded",
          superseded_at: now,
          error: %{"reason" => "turn_completion_subsumed_acceptance"},
          updated_at: now
        ]
      )

    {deleted_count, superseded_count}
  end

  defp after_commit({:ok, result}, turn_ref, final_response_id, outcome, final_text) do
    AIReplyPreview.stop(turn_ref.actor_event_id)
    Observability.finish_turn(turn_ref.actor_event_id, output: final_text, outcome: outcome)

    Logging.info(
      "signals_gateway.actor_turn_completed",
      "SignalsGateway committed an explicit Agent turn completion",
      %{
        agent_uid: turn_ref.agent_uid,
        session_id: turn_ref.session_id,
        actor_event_id: turn_ref.actor_event_id,
        final_response_id: final_response_id,
        outcome: outcome,
        status: result.status
      }
    )

    {:ok, result}
  end

  defp after_commit(
         {:error, _reason} = error,
         _turn_ref,
         _response_id,
         _outcome,
         _final_text
       ),
       do: error

  defp completion_outcome("loop_finished"), do: {:ok, "loop_finished"}
  defp completion_outcome("iteration_exhausted"), do: {:ok, "iteration_exhausted"}
  defp completion_outcome("silent"), do: {:ok, "silent"}

  defp completion_outcome(_outcome), do: {:error, :invalid_turn_completion_outcome}

  # A reply outcome always names the adopted Response. A silent outcome names
  # it only when the worker ran a model loop.
  defp completion_response_id(final_response_id, "silent") do
    case presence(final_response_id) do
      nil -> {:ok, nil}
      final_response_id -> validate_final_response_id(final_response_id)
    end
  end

  defp completion_response_id(final_response_id, _outcome) do
    with {:ok, final_response_id} <- required_text(final_response_id) do
      validate_final_response_id(final_response_id)
    end
  end

  defp validate_final_response_id("resp_" <> uuid = final_response_id) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> {:ok, final_response_id}
      :error -> {:error, :invalid_final_response_id}
    end
  end

  defp validate_final_response_id(_response_id), do: {:error, :invalid_final_response_id}

  defp completion_anchor(completion, outcome) do
    %{final_response_id: completion.final_response_id, turn_outcome: outcome}
  end

  defp validate_completion_anchor(
         %ActorEvent{final_response_id: final_response_id, turn_outcome: outcome},
         final_response_id,
         outcome
       ),
       do: :ok

  defp validate_completion_anchor(%ActorEvent{}, _final_response_id, _outcome),
    do: {:error, :actor_turn_completion_conflict}

  defp required_text(value) when is_binary(value) do
    case presence(value) do
      nil -> {:error, {:required_text_blank, "final_response_id"}}
      value -> {:ok, value}
    end
  end

  defp required_text(_value), do: {:error, {:required_text_missing, "final_response_id"}}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp presence(_value), do: nil
end
