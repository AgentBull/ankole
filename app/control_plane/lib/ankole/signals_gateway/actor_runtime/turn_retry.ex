defmodule Ankole.SignalsGateway.ActorRuntime.TurnRetry do
  @moduledoc """
  Coordinates retry control for already-started worker turns.

  Two user-visible events share the same runtime shape:

    * `/retry` while a generation is still running.
    * provider-side removal of one source entry inside an in-flight merged IM batch.

  In both cases the control plane fences the old turn immediately, leaves or
  rewrites the actor event as retryable durable work, then sends the worker a
  best-effort `turn_control retry` event so it can stop spending tokens.
  """

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission

  @doc """
  Fences a live worker turn and marks its events retryable inside a transaction.
  """
  @spec retry_live_turn_in_tx(module(), map(), ActorEvent.t(), DateTime.t()) ::
          {:ok, map() | :no_live_turn} | {:error, term()}
  def retry_live_turn_in_tx(repo, actor_key, %ActorEvent{} = command_event, now) do
    with deliveries <- live_deliveries_for_actor(repo, actor_key),
         %{} <-
           AIGatewayLink.active_conversation_for_update(
             repo,
             actor_key.agent_uid,
             actor_key.session_id
           ),
         actor_event_id when is_binary(actor_event_id) <- current_actor_event_id(deliveries),
         turn <- AIGatewayLink.generating_turn_in_tx(repo, actor_key, actor_event_id),
         retry_event_ids when retry_event_ids != [] <- retry_actor_event_ids(turn, deliveries),
         {:ok, retry_events} <-
           mark_events_for_retry(repo, retry_event_ids, actor_event_id, now, "command.retry"),
         {:ok, cancelled_message} <-
           TurnLifecycle.cancel_started_turn_in_tx(
             repo,
             actor_key,
             actor_event_id,
             now,
             "command.retry"
           ),
         {:ok, completed_event} <-
           Actors.complete_command_event_in_tx(repo, command_event,
             completed_at: now,
             outbox_intents: []
           ) do
      {:ok,
       %{
         status: :command_consumed,
         command: command_event.type,
         retry_actor_events: retry_events,
         retry_controls: retry_controls(live_deliveries(deliveries), "command.retry"),
         ai_message: cancelled_message,
         actor_event: completed_event
       }}
    else
      nil -> {:ok, :no_live_turn}
      [] -> {:ok, :no_live_turn}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Retracts one provider source entry from live actor event inside a transaction.
  """
  @spec retract_source_entry_in_tx(module(), map(), term(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def retract_source_entry_in_tx(repo, fact, kind, now) do
    fact
    |> candidate_events_for_source_entry(repo)
    |> Enum.map(&retract_source_entry_from_event(repo, &1, fact, kind, now))
    |> collect_results()
    |> case do
      {:ok, results} ->
        results = Enum.reject(results, &is_nil/1)

        {:ok,
         %{
           results: results,
           canceled_actor_events: Enum.count(results, &(&1.status == :canceled)),
           retried_actor_events: Enum.count(results, &(&1.status == :retried)),
           retry_controls: results |> Enum.flat_map(& &1.retry_controls) |> Enum.uniq()
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Dispatches best-effort retry controls described by a successful mutation result.
  """
  @spec dispatch_retry_controls({:ok, map()} | term()) :: {:ok, map()} | term()
  def dispatch_retry_controls({:ok, result}) when is_map(result) do
    controls = retry_controls_from_result(result)

    outcomes = Enum.map(controls, &dispatch_retry_control/1)

    {:ok, Map.put(result, :retry_control_outcomes, outcomes)}
  end

  def dispatch_retry_controls(other), do: other

  defp retry_controls_from_result(result) do
    direct = Map.get(result, :retry_controls, [])
    retractions = result |> Map.get(:runtime_retractions, %{}) |> Map.get(:retry_controls, [])

    (direct ++ retractions)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dispatch_retry_control(%{route: route, turn_ref: turn_ref, reason: reason} = control) do
    payload = Map.get(control, :payload, %{}) |> Map.put("reason", reason)
    envelope = TurnEnvelope.turn_control(turn_ref, "retry", payload)

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        Map.put(control, :send_outcome, "sent_or_queued")

      {:error, reason} ->
        WorkerAdmission.mark_route_unusable(route, reason)

        control
        |> Map.put(:send_outcome, reason_text(reason))
        |> Map.put(:send_error, reason)
    end
  end

  defp live_deliveries_for_actor(repo, actor_key) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^actor_key.agent_uid)
    |> where([delivery], delivery.session_id == ^actor_key.session_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp live_deliveries_for_event(repo, %ActorEvent{} = input) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id == ^input.id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp mark_events_for_retry(repo, event_ids, actor_event_id, now, reason) do
    ActorEvent
    |> where([input], input.id in ^event_ids)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.map(&mark_event_for_retry(repo, &1, actor_event_id, now, reason))
    |> collect_results()
    |> case do
      {:ok, []} -> {:error, :retry_actor_event_not_found}
      result -> result
    end
  end

  defp mark_event_for_retry(repo, %ActorEvent{} = input, actor_event_id, now, reason) do
    payload = put_retry_metadata(input.payload, actor_event_id, reason, %{})

    input
    |> ActorEvent.changeset(%{payload: payload, available_at: now})
    |> repo.update()
  end

  defp candidate_events_for_source_entry(fact, repo) do
    ActorEvent
    |> where([input], input.agent_uid == ^fact.agent_uid)
    |> where([input], input.binding_name == ^fact.binding_name)
    |> where([input], input.signal_channel_id == ^fact.signal_channel_id)
    |> where([input], input.input_state == "open")
    |> where([input], is_nil(input.completed_at))
    |> maybe_where_thread(fact.provider_thread_id)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.filter(&event_mentions_provider_entry?(&1, fact.source_entry_id))
  end

  defp maybe_where_thread(query, nil), do: query

  defp maybe_where_thread(query, provider_thread_id) do
    where(query, [input], input.provider_thread_id == ^provider_thread_id)
  end

  defp event_mentions_provider_entry?(%ActorEvent{} = input, source_entry_id) do
    input.source_entry_id == source_entry_id or
      Enum.any?(event_entries(input), &(&1["source_entry_id"] == source_entry_id))
  end

  defp retract_source_entry_from_event(repo, %ActorEvent{} = input, fact, kind, now) do
    entries = event_entries(input)

    case source_entry_retraction(entries, input, fact.source_entry_id) do
      :no_match ->
        {:ok, nil}

      :cancel ->
        with {:ok, cancellation} <-
               cancel_event_live_turn(repo, input, kind, now),
             {:ok, _deleted} <- repo.delete(input) do
          {:ok,
           %{
             status: :canceled,
             actor_event: input,
             ai_message: cancellation.message,
             retry_controls: cancellation.retry_controls
           }}
        end

      {:replace, remaining_entries} ->
        with {:ok, cancellation} <-
               cancel_event_live_turn(repo, input, kind, now),
             {:ok, updated_event} <-
               replace_event_entries(
                 repo,
                 input,
                 remaining_entries,
                 fact,
                 kind,
                 now,
                 cancellation.message
               ) do
          {:ok,
           %{
             status: :retried,
             actor_event: updated_event,
             ai_message: cancellation.message,
             retry_controls: cancellation.retry_controls
           }}
        end
    end
  end

  defp source_entry_retraction(entries, %ActorEvent{}, source_entry_id)
       when is_list(entries) and entries != [] do
    remaining = Enum.reject(entries, &(&1["source_entry_id"] == source_entry_id))

    cond do
      length(remaining) == length(entries) -> :no_match
      remaining == [] -> :cancel
      true -> {:replace, remaining}
    end
  end

  defp source_entry_retraction(
         _entries,
         %ActorEvent{source_entry_id: direct_entry_id},
         source_entry_id
       )
       when direct_entry_id == source_entry_id,
       do: :cancel

  defp source_entry_retraction(_entries, _input, _source_entry_id), do: :no_match

  defp cancel_event_live_turn(repo, %ActorEvent{} = input, reason, now) do
    deliveries = live_deliveries_for_event(repo, input)

    case deliveries do
      [] ->
        {:ok, %{message: nil, retry_controls: []}}

      [delivery | _rest] ->
        actor_event_id = delivery.actor_event_id_fence

        with {:ok, cancelled_message} <-
               TurnLifecycle.cancel_started_turn_in_tx(
                 repo,
                 %{agent_uid: input.agent_uid, session_id: input.session_id},
                 actor_event_id,
                 now,
                 reason
               ) do
          {:ok,
           %{
             message: cancelled_message,
             retry_controls: retry_controls(deliveries, reason_text(reason))
           }}
        end
    end
  end

  defp replace_event_entries(repo, input, entries, fact, kind, now, turn) do
    summary = merged_entry_summary(entries)

    payload =
      input.payload
      |> replace_payload_entries(entries, summary, fact.source_entry_id, now)
      |> maybe_put_retry_metadata(turn, reason_text(kind), %{
        "removed_source_entry_id" => fact.source_entry_id
      })

    attrs = %{
      payload: payload,
      source_entry_id: summary["source_entry_id"],
      available_at: now
    }

    attrs =
      case turn do
        %{} ->
          Map.put(attrs, :source_event_id, "retry:#{input.id}:without:#{fact.source_entry_id}")

        nil ->
          attrs
      end

    input
    |> ActorEvent.changeset(attrs)
    |> repo.update()
  end

  defp replace_payload_entries(payload, entries, summary, removed_source_entry_id, now)
       when is_map(payload) do
    data = Map.get(payload, "data", %{})

    data =
      data
      |> Map.put("entry", summary)
      |> Map.put("entries", entries)
      |> update_observed_messages(removed_source_entry_id)
      |> update_ambient_batch(entries, now)

    Map.put(payload, "data", data)
  end

  defp replace_payload_entries(_payload, entries, summary, _removed_source_entry_id, _now) do
    %{"data" => %{"entry" => summary, "entries" => entries}}
  end

  defp maybe_put_retry_metadata(payload, %{actor_event_id: actor_event_id}, reason, extra)
       when is_binary(actor_event_id) do
    put_retry_metadata(payload, actor_event_id, reason, extra)
  end

  defp maybe_put_retry_metadata(payload, %{} = response, reason, extra) do
    case AIGatewayLink.actor_event_id(response) do
      actor_event_id when is_binary(actor_event_id) ->
        put_retry_metadata(payload, actor_event_id, reason, extra)

      nil ->
        payload
    end
  end

  defp maybe_put_retry_metadata(payload, _turn, _reason, _extra), do: payload

  @doc false
  @spec put_retry_metadata(map(), String.t(), String.t(), map()) :: map()
  def put_retry_metadata(payload, retry_actor_event_id, reason, extra)
      when is_map(payload) do
    entry =
      payload
      |> get_in(["data", "entry"])
      |> case do
        %{} = entry -> entry
        _value -> %{}
      end
      |> Map.merge(extra)
      |> Map.put("retry_of_actor_event_id", retry_actor_event_id)
      |> Map.put("retry_reason", reason)

    data =
      payload
      |> Map.get("data", %{})
      |> Map.put("entry", entry)

    Map.put(payload, "data", data)
  end

  def put_retry_metadata(_payload, retry_actor_event_id, reason, extra) do
    put_retry_metadata(
      %{"data" => %{"entry" => %{}}},
      retry_actor_event_id,
      reason,
      extra
    )
  end

  defp update_observed_messages(data, removed_source_entry_id) do
    case Map.get(data, "observed_messages") do
      messages when is_list(messages) ->
        Map.put(
          data,
          "observed_messages",
          Enum.reject(messages, &(&1["source_entry_id"] == removed_source_entry_id))
        )

      _value ->
        data
    end
  end

  defp update_ambient_batch(%{"ambient_batch" => batch} = data, entries, now)
       when is_map(batch) do
    batch =
      batch
      |> Map.put("size", length(entries))
      |> Map.put(
        "first_source_entry_id",
        entries |> List.first() |> Map.get("source_entry_id")
      )
      |> Map.put("last_source_entry_id", entries |> List.last() |> Map.get("source_entry_id"))
      |> Map.put("updated_at", DateTime.to_iso8601(now))

    Map.put(data, "ambient_batch", batch)
  end

  defp update_ambient_batch(data, _entries, _now), do: data

  defp merged_entry_summary(entries) do
    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", merged_entry_text(entries))
    |> put_nonempty("attachments", merged_entry_list(entries, "attachments"))
    |> put_nonempty("links", merged_entry_list(entries, "links"))
    |> put_nonempty("mentions", merged_entry_list(entries, "mentions"))
  end

  defp merged_entry_text(entries) do
    entries
    |> Enum.map(& &1["text"])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp merged_entry_list(entries, key) do
    Enum.flat_map(entries, fn entry ->
      case entry[key] do
        values when is_list(values) -> values
        _value -> []
      end
    end)
  end

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, values), do: Map.put(map, key, values)

  defp event_entries(%ActorEvent{payload: %{"data" => %{"entries" => entries}}})
       when is_list(entries),
       do: entries

  defp event_entries(_input), do: []

  defp retry_controls(deliveries, reason) do
    deliveries
    |> Enum.map(fn delivery ->
      %{
        route: delivery.transport_route || delivery.worker_id,
        turn_ref: turn_ref(delivery),
        reason: reason
      }
    end)
    |> Enum.reject(&is_nil(&1.route))
    |> Enum.uniq()
  end

  defp live_deliveries(deliveries) do
    Enum.filter(deliveries, &(&1.state in ActorEventDelivery.live_states()))
  end

  defp retry_actor_event_ids(%{request_ref_actor_event_ids: request_ref_ids}, deliveries) do
    deliveries
    |> Enum.map(& &1.actor_event_id)
    |> Kernel.++(request_ref_ids)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp retry_actor_event_ids(nil, deliveries) do
    deliveries
    |> Enum.map(& &1.actor_event_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp turn_ref(%ActorEventDelivery{} = delivery) do
    TurnRef.from_delivery(delivery)
  end

  defp current_actor_event_id([
         %ActorEventDelivery{actor_event_id_fence: actor_event_id} | _rest
       ]),
       do: actor_event_id

  defp current_actor_event_id(_deliveries), do: nil

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
