defmodule Ankole.SignalsGateway.ActorTurnCompletion do
  @moduledoc """
  Commits one explicit Agent Computer turn completion into SignalsGateway.

  A terminal LLM Response is only immutable input to this operation. The
  worker's `turn_completed` envelope is the sole declaration that the Agent
  loop has ended; this module then validates runtime fences and atomically
  commits provider outbox intents plus ActorEvent consumption.
  """

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.ReplyInteractions

  @live_activation_statuses ~w(starting active draining)
  @outcomes ~w(loop_finished iteration_exhausted)

  @spec handle(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle(envelope, opts \\ []) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_completed")

    with {:ok, turn_ref} <- TurnRef.from_request(payload),
         {:ok, final_response_id} <- required_text(payload, "final_response_id"),
         :ok <- validate_final_response_id(final_response_id),
         {:ok, outcome} <- completion_outcome(payload) do
      case completed_actor_event(turn_ref) do
        %ActorEvent{} = event ->
          with :ok <- validate_completion_anchor(event, final_response_id, outcome) do
            {:ok, %{status: :already_completed, actor_event: event, outcome: outcome}}
            |> after_commit(turn_ref, final_response_id, outcome)
          end

        nil ->
          with {:ok, completion} <-
                 AIGatewayLink.load_turn_completion(turn_ref, final_response_id) do
            now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

            Repo.transact(fn repo ->
              commit_in_tx(repo, turn_ref, completion, outcome, now)
            end)
            |> after_commit(turn_ref, final_response_id, outcome)
          end
      end
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
    case lock_actor_event(repo, turn_ref) do
      %ActorEvent{completed_at: %DateTime{}} = event ->
        final_response_id = "resp_#{completion.final_response.id}"

        with :ok <- validate_completion_anchor(event, final_response_id, outcome) do
          {:ok, %{status: :already_completed, actor_event: event, outcome: outcome}}
        end

      %ActorEvent{} = event ->
        with {:ok, activation} <- lock_and_validate_activation(repo, turn_ref, now),
             {:ok, deliveries} <- lock_and_validate_deliveries(repo, turn_ref) do
          case Actors.ensure_event_source_live_in_tx(repo, event, now) do
            :ok ->
              commit_live_source_in_tx(
                repo,
                event,
                activation,
                deliveries,
                turn_ref,
                completion,
                outcome,
                now
              )

            {:error, :actor_event_canceled} ->
              cancel_tombstoned_source_in_tx(
                repo,
                event,
                activation,
                deliveries,
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
    with {:ok, outboxes} <- commit_outboxes(repo, event, completion, outcome, now),
         {:ok, completed_events} <-
           complete_accepted_events(repo, event, deliveries, turn_ref, completion, outcome, now),
         {deleted_count, superseded_count} <-
           cleanup_deliveries(repo, turn_ref.actor_event_id, now),
         {:ok, activation} <- TurnLifecycle.mark_activation_idle_in_tx(repo, activation, now) do
      {:ok,
       %{
         status: :turn_completed,
         outcome: outcome,
         actor_event: completed_main_event(completed_events, event),
         activation: activation,
         completed_actor_events: completed_events,
         outboxes: outboxes,
         deleted_deliveries: deleted_count,
         superseded_deliveries: superseded_count
       }}
    end
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
         {:ok, activation} <- TurnLifecycle.mark_activation_idle_in_tx(repo, activation, now) do
      {:ok,
       %{
         status: :turn_canceled,
         reason: :actor_event_canceled,
         outcome: outcome,
         actor_event: completed_main_event(completed_events, event),
         activation: activation,
         completed_actor_events: completed_events,
         outboxes: %{attachments: [], clarify: nil, final: nil},
         deleted_deliveries: deleted_count,
         superseded_deliveries: superseded_count
       }}
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

  defp lock_and_validate_activation(repo, turn_ref, now) do
    activation =
      ActorSessionActivation
      |> where([item], item.agent_uid == ^turn_ref.agent_uid)
      |> where([item], item.session_id == ^turn_ref.session_id)
      |> where([item], item.activation_uid == ^turn_ref.activation_uid)
      |> repo.one()

    with %ActorSessionActivation{assigned_worker_id: worker_id} when is_binary(worker_id) <-
           activation,
         %AgentComputerWorker{} <- lock_worker(repo, worker_id),
         %ActorSessionActivation{} = activation <-
           lock_activation(repo, turn_ref, worker_id),
         :ok <- validate_activation(activation, turn_ref, now) do
      {:ok, activation}
    else
      {:error, _reason} = error -> error
      _missing -> {:error, :actor_runtime_fence_not_found}
    end
  end

  defp lock_worker(repo, worker_id) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^worker_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_activation(repo, turn_ref, worker_id) do
    ActorSessionActivation
    |> where([item], item.agent_uid == ^turn_ref.agent_uid)
    |> where([item], item.session_id == ^turn_ref.session_id)
    |> where([item], item.activation_uid == ^turn_ref.activation_uid)
    |> where([item], item.assigned_worker_id == ^worker_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp validate_activation(activation, turn_ref, now) do
    cond do
      activation.status not in @live_activation_statuses ->
        {:error, :activation_not_live}

      DateTime.compare(activation.lease_expires_at, now) != :gt ->
        {:error, :activation_lease_expired}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :stale_actor_epoch}

      activation.revision < turn_ref.revision ->
        {:error, :stale_revision}

      activation.current_actor_event_id != turn_ref.actor_event_id ->
        {:error, :stale_actor_event_id}

      true ->
        :ok
    end
  end

  defp lock_and_validate_deliveries(repo, turn_ref) do
    deliveries =
      ActorEventDelivery
      |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
      |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
      |> lock("FOR UPDATE")
      |> repo.all()

    case deliveries do
      [] -> {:error, :actor_runtime_fence_not_found}
      deliveries -> validate_deliveries(deliveries, turn_ref)
    end
  end

  defp validate_deliveries(deliveries, turn_ref) do
    mismatch = Enum.find_value(deliveries, &delivery_mismatch(&1, turn_ref))

    cond do
      mismatch ->
        {:error, mismatch}

      not Enum.any?(deliveries, fn delivery ->
        delivery.actor_event_id == turn_ref.actor_event_id and delivery.state == "accepted"
      end) ->
        {:error, :main_delivery_not_accepted}

      true ->
        {:ok, deliveries}
    end
  end

  defp delivery_mismatch(delivery, turn_ref) do
    cond do
      delivery.agent_uid != turn_ref.agent_uid -> :stale_actor_key
      delivery.session_id != turn_ref.session_id -> :stale_actor_key
      delivery.activation_uid != turn_ref.activation_uid -> :stale_activation_uid
      delivery.actor_epoch != turn_ref.actor_epoch -> :stale_actor_epoch
      delivery.actor_event_id_fence != turn_ref.actor_event_id -> :stale_actor_event_id
      delivery.revision > turn_ref.revision -> :stale_revision
      true -> nil
    end
  end

  defp commit_outboxes(repo, event, completion, outcome, now) do
    if AIReplyPreview.im_visible_event?(event) do
      commit_im_outboxes(repo, event, completion, outcome, now)
    else
      {:ok, %{attachments: [], clarify: nil, final: nil}}
    end
  end

  defp commit_im_outboxes(repo, event, completion, outcome, now) do
    opts = [turn_completion_outcome: outcome]
    final_text = completion.final_text || ""

    with {:ok, attachments} <-
           Outbox.commit_reply_attachment_outboxes_in_tx(
             repo,
             event,
             completion.final_response.id,
             final_text,
             completion.attachments,
             opts
           ),
         {:ok, clarify} <- commit_clarify_outbox(repo, event, completion, opts, now),
         {:ok, final} <- commit_final_outbox(repo, event, completion, opts) do
      {:ok, %{attachments: attachments, clarify: clarify, final: final}}
    end
  end

  defp commit_clarify_outbox(_repo, _event, %{clarify_prompt: nil}, _opts, _now),
    do: {:ok, nil}

  defp commit_clarify_outbox(repo, event, completion, opts, now) do
    if AIReplyPreview.im_visible_event?(event) do
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

  defp commit_final_outbox(repo, event, completion, opts) do
    if AIReplyPreview.im_visible_event?(event) and is_nil(completion.clarify_prompt) and
         is_binary(completion.final_text) do
      Outbox.commit_final_reply_outbox_in_tx(
        repo,
        event,
        completion.final_response,
        completion.final_text,
        Keyword.put(opts, :attachment_count, length(completion.attachments))
      )
    else
      {:ok, nil}
    end
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
      |> Enum.filter(&(&1.state == "accepted" and &1.revision <= turn_ref.revision))
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
          error: %{"reason" => "turn_completed_before_acceptance"},
          updated_at: now
        ]
      )

    {deleted_count, superseded_count}
  end

  defp after_commit({:ok, result}, turn_ref, final_response_id, outcome) do
    AIReplyPreview.stop(turn_ref.actor_event_id)

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

  defp after_commit({:error, _reason} = error, _turn_ref, _response_id, _outcome), do: error

  defp completion_outcome(payload) do
    case map_value(payload, "outcome") do
      outcome when outcome in @outcomes -> {:ok, outcome}
      _outcome -> {:error, :invalid_turn_completion_outcome}
    end
  end

  defp validate_final_response_id("resp_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_final_response_id}
    end
  end

  defp validate_final_response_id(_response_id), do: {:error, :invalid_final_response_id}

  defp completion_anchor(completion, outcome) do
    %{
      final_response_id: "resp_#{completion.final_response.id}",
      turn_outcome: outcome
    }
  end

  defp validate_completion_anchor(
         %ActorEvent{final_response_id: final_response_id, turn_outcome: outcome},
         final_response_id,
         outcome
       ),
       do: :ok

  defp validate_completion_anchor(%ActorEvent{}, _final_response_id, _outcome),
    do: {:error, :actor_turn_completion_conflict}

  defp required_text(map, key) do
    case map_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:required_text_blank, key}}
          value -> {:ok, value}
        end

      _value ->
        {:error, {:required_text_missing, key}}
    end
  end

  defp unwrap_body(%{"body" => %{"type" => type} = body}, type), do: Map.get(body, type, %{})
  defp unwrap_body(%{body: %{type: type} = body}, type), do: Map.get(body, type, %{})

  defp unwrap_body(payload, type) when is_map(payload),
    do: Map.get(payload, type) || Map.get(payload, String.to_atom(type)) || payload

  defp map_value(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
