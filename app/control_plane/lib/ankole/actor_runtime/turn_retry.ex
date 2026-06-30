defmodule Ankole.ActorRuntime.TurnRetry do
  @moduledoc """
  Coordinates retry control for already-started worker turns.

  Two user-visible events share the same runtime shape:

    * `/retry` while a generation is still running.
    * provider-side removal of one source entry inside an in-flight merged IM batch.

  In both cases the control plane fences the old turn immediately, leaves or
  rewrites the actor input as retryable durable work, then sends the worker a
  best-effort `turn_control retry` event so it can stop spending tokens.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.TurnEnvelope
  alias Ankole.ActorRuntime.WorkerAdmission

  @doc """
  Fences an active generation and marks its inputs retryable inside a transaction.
  """
  @spec retry_active_generation_in_tx(module(), map(), ActorInput.t(), DateTime.t()) ::
          {:ok, map() | :no_active_generation} | {:error, term()}
  def retry_active_generation_in_tx(repo, actor_key, %ActorInput{} = command_input, now) do
    with %Conversation{} = conversation <- active_conversation_for_update(repo, actor_key),
         true <- active_generation?(conversation),
         %LlmTurn{} = turn <- started_turn_for_generation(repo, conversation),
         deliveries <- deliveries_for_turn(repo, turn.id),
         retry_input_ids when retry_input_ids != [] <- retry_actor_input_ids(turn, deliveries),
         {:ok, retry_inputs} <-
           mark_inputs_for_retry(repo, retry_input_ids, turn, now, "command.retry"),
         {:ok, _conversation} <-
           cancel_conversation_generation(repo, conversation, now, "command.retry"),
         {:ok, cancelled_turn} <- AIAgent.cancel_turn_in_tx(repo, turn, "command.retry", now),
         {_count, _rows} <- supersede_turn_deliveries(repo, turn.id, now, "command.retry"),
         {:ok, consumption} <-
           Actors.consume_command_input_in_tx(repo, command_input,
             consumed_at: now,
             outbox_intents: []
           ) do
      {:ok,
       %{
         status: :command_consumed,
         command: command_input.type,
         retry_actor_inputs: retry_inputs,
         retry_controls: retry_controls(live_deliveries(deliveries), "command.retry"),
         llm_turn: cancelled_turn,
         consumption: consumption
       }}
    else
      false -> {:ok, :no_active_generation}
      nil -> {:ok, :no_active_generation}
      [] -> {:ok, :no_active_generation}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Retracts one provider source entry from live actor input inside a transaction.
  """
  @spec retract_source_entry_in_tx(module(), map(), term(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def retract_source_entry_in_tx(repo, fact, kind, now) do
    fact
    |> candidate_inputs_for_source_entry(repo)
    |> Enum.map(&retract_source_entry_from_input(repo, &1, fact, kind, now))
    |> collect_results()
    |> case do
      {:ok, results} ->
        results = Enum.reject(results, &is_nil/1)

        {:ok,
         %{
           results: results,
           canceled_actor_inputs: Enum.count(results, &(&1.status == :canceled)),
           retried_actor_inputs: Enum.count(results, &(&1.status == :retried)),
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
        control |> Map.put(:send_outcome, Atom.to_string(reason)) |> Map.put(:send_error, reason)
    end
  end

  defp active_conversation_for_update(repo, actor_key) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp active_generation?(%Conversation{generation: generation}) when is_map(generation) do
    Conversation.generation_active?(generation)
  end

  defp active_generation?(_conversation), do: false

  defp started_turn_for_generation(repo, %Conversation{generation: generation} = conversation)
       when is_map(generation) do
    AIAgent.started_turn_for_lease(repo, conversation, generation["lease_id"])
  end

  defp deliveries_for_turn(repo, llm_turn_id) do
    ActorInputDelivery
    |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp live_deliveries_for_input(repo, %ActorInput{} = input) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id == ^input.id)
    |> where([delivery], delivery.state in ^ActorInputDelivery.live_states())
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp mark_inputs_for_retry(repo, input_ids, %LlmTurn{} = turn, now, reason) do
    ActorInput
    |> where([input], input.id in ^input_ids)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.map(&mark_input_for_retry(repo, &1, turn, now, reason))
    |> collect_results()
    |> case do
      {:ok, []} -> {:error, :retry_actor_input_not_found}
      result -> result
    end
  end

  defp mark_input_for_retry(repo, %ActorInput{} = input, %LlmTurn{} = turn, now, reason) do
    payload = put_retry_metadata(input.payload, turn.id, input.id, reason, %{})

    input
    |> ActorInput.changeset(%{payload: payload, available_at: now})
    |> repo.update()
  end

  defp candidate_inputs_for_source_entry(fact, repo) do
    ActorInput
    |> where([input], input.agent_uid == ^fact.agent_uid)
    |> where([input], input.binding_name == ^fact.binding_name)
    |> where([input], input.signal_channel_id == ^fact.signal_channel_id)
    |> maybe_where_thread(fact.provider_thread_id)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.filter(&input_mentions_provider_entry?(&1, fact.provider_entry_id))
  end

  defp maybe_where_thread(query, nil), do: query

  defp maybe_where_thread(query, provider_thread_id) do
    where(query, [input], input.provider_thread_id == ^provider_thread_id)
  end

  defp input_mentions_provider_entry?(%ActorInput{} = input, provider_entry_id) do
    input.provider_entry_id == provider_entry_id or
      Enum.any?(input_entries(input), &(&1["provider_entry_id"] == provider_entry_id))
  end

  defp retract_source_entry_from_input(repo, %ActorInput{} = input, fact, kind, now) do
    entries = input_entries(input)

    case source_entry_retraction(entries, input, fact.provider_entry_id) do
      :no_match ->
        {:ok, nil}

      :cancel ->
        with {:ok, cancellation} <-
               cancel_input_live_turn(repo, input, kind, now, retract_messages?: true),
             {:ok, _deleted} <- repo.delete(input) do
          {:ok,
           %{
             status: :canceled,
             actor_input: input,
             llm_turn: cancellation.turn,
             retry_controls: cancellation.retry_controls
           }}
        end

      {:replace, remaining_entries} ->
        with {:ok, cancellation} <-
               cancel_input_live_turn(repo, input, kind, now, retract_messages?: true),
             {:ok, updated_input} <-
               replace_input_entries(
                 repo,
                 input,
                 remaining_entries,
                 fact,
                 kind,
                 now,
                 cancellation.turn
               ) do
          {:ok,
           %{
             status: :retried,
             actor_input: updated_input,
             llm_turn: cancellation.turn,
             retry_controls: cancellation.retry_controls
           }}
        end
    end
  end

  defp source_entry_retraction(entries, %ActorInput{}, provider_entry_id)
       when is_list(entries) and entries != [] do
    remaining = Enum.reject(entries, &(&1["provider_entry_id"] == provider_entry_id))

    cond do
      length(remaining) == length(entries) -> :no_match
      remaining == [] -> :cancel
      true -> {:replace, remaining}
    end
  end

  defp source_entry_retraction(
         _entries,
         %ActorInput{provider_entry_id: direct_entry_id},
         provider_entry_id
       )
       when direct_entry_id == provider_entry_id,
       do: :cancel

  defp source_entry_retraction(_entries, _input, _provider_entry_id), do: :no_match

  defp cancel_input_live_turn(repo, %ActorInput{} = input, reason, now, opts) do
    deliveries = live_deliveries_for_input(repo, input)

    case deliveries do
      [] ->
        {:ok, %{turn: nil, retry_controls: []}}

      [delivery | _rest] ->
        with %LlmTurn{} = turn <- lock_turn(repo, delivery.llm_turn_id),
             %Conversation{} = conversation <- lock_conversation(repo, turn.conversation_id),
             {:ok, _conversation} <-
               cancel_conversation_generation(repo, conversation, now, reason),
             {:ok, cancelled_turn} <- AIAgent.cancel_turn_in_tx(repo, turn, reason, now),
             {:ok, _messages} <- maybe_retract_turn_messages(repo, turn, reason, now, opts),
             {_count, _rows} <- supersede_turn_deliveries(repo, turn.id, now, reason) do
          {:ok,
           %{
             turn: cancelled_turn,
             retry_controls: retry_controls(deliveries, reason_text(reason))
           }}
        else
          nil -> {:ok, %{turn: nil, retry_controls: []}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp maybe_retract_turn_messages(repo, %LlmTurn{} = turn, reason, now, opts) do
    case Keyword.get(opts, :retract_messages?, false) do
      true -> AIAgent.retract_turn_input_messages_in_tx(repo, turn, reason, now)
      false -> {:ok, []}
    end
  end

  defp replace_input_entries(repo, input, entries, fact, kind, now, turn) do
    summary = merged_entry_summary(entries)

    payload =
      input.payload
      |> replace_payload_entries(entries, summary, fact.provider_entry_id, now)
      |> maybe_put_retry_metadata(turn, input.id, reason_text(kind), %{
        "removed_provider_entry_id" => fact.provider_entry_id
      })

    attrs = %{
      payload: payload,
      provider_entry_id: summary["provider_entry_id"],
      available_at: now
    }

    attrs =
      case turn do
        %LlmTurn{} ->
          Map.put(attrs, :ingress_event_id, "retry:#{input.id}:without:#{fact.provider_entry_id}")

        nil ->
          attrs
      end

    input
    |> ActorInput.changeset(attrs)
    |> repo.update()
  end

  defp replace_payload_entries(payload, entries, summary, removed_provider_entry_id, now)
       when is_map(payload) do
    data = Map.get(payload, "data", %{})

    data =
      data
      |> Map.put("entry", summary)
      |> Map.put("entries", entries)
      |> update_observed_messages(removed_provider_entry_id)
      |> update_ambient_batch(entries, now)

    Map.put(payload, "data", data)
  end

  defp replace_payload_entries(_payload, entries, summary, _removed_provider_entry_id, _now) do
    %{"data" => %{"entry" => summary, "entries" => entries}}
  end

  defp maybe_put_retry_metadata(payload, %LlmTurn{} = turn, actor_input_id, reason, extra) do
    put_retry_metadata(payload, turn.id, actor_input_id, reason, extra)
  end

  defp maybe_put_retry_metadata(payload, _turn, _actor_input_id, _reason, _extra), do: payload

  defp put_retry_metadata(payload, retry_turn_id, actor_input_id, reason, extra)
       when is_map(payload) do
    entry =
      payload
      |> get_in(["data", "entry"])
      |> case do
        %{} = entry -> entry
        _value -> %{}
      end
      |> Map.merge(extra)
      |> Map.put("retry_of_llm_turn_id", retry_turn_id)
      |> Map.put("retry_of_actor_input_id", actor_input_id)
      |> Map.put("retry_reason", reason)

    data =
      payload
      |> Map.get("data", %{})
      |> Map.put("entry", entry)

    Map.put(payload, "data", data)
  end

  defp put_retry_metadata(_payload, retry_turn_id, actor_input_id, reason, extra) do
    put_retry_metadata(
      %{"data" => %{"entry" => %{}}},
      retry_turn_id,
      actor_input_id,
      reason,
      extra
    )
  end

  defp update_observed_messages(data, removed_provider_entry_id) do
    case Map.get(data, "observed_messages") do
      messages when is_list(messages) ->
        Map.put(
          data,
          "observed_messages",
          Enum.reject(messages, &(&1["provider_entry_id"] == removed_provider_entry_id))
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
        "first_provider_entry_id",
        entries |> List.first() |> Map.get("provider_entry_id")
      )
      |> Map.put("last_provider_entry_id", entries |> List.last() |> Map.get("provider_entry_id"))
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

  defp input_entries(%ActorInput{payload: %{"data" => %{"entries" => entries}}})
       when is_list(entries),
       do: entries

  defp input_entries(_input), do: []

  defp cancel_conversation_generation(repo, %Conversation{} = conversation, now, reason) do
    generation = conversation.generation || %{}

    generation =
      case generation["lease_id"] do
        lease_id when is_binary(lease_id) and lease_id != "" ->
          generation
          |> Map.put("cancelled_at", DateTime.to_iso8601(now))
          |> Map.put("cancel_reason", reason_text(reason))

        _value ->
          generation
      end

    conversation
    |> Conversation.changeset(%{generation: generation})
    |> repo.update()
  end

  defp supersede_turn_deliveries(repo, llm_turn_id, now, reason) do
    ActorInputDelivery
    |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
    |> where([delivery], delivery.state in ^ActorInputDelivery.live_states())
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

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
    Enum.filter(deliveries, &(&1.state in ActorInputDelivery.live_states()))
  end

  defp retry_actor_input_ids(%LlmTurn{} = turn, deliveries) do
    deliveries
    |> Enum.map(& &1.actor_input_id)
    |> Kernel.++(request_ref_actor_input_ids(turn.request_refs))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp request_ref_actor_input_ids(request_refs) when is_list(request_refs) do
    Enum.flat_map(request_refs, fn
      %{"actor_input_id" => actor_input_id} when is_binary(actor_input_id) -> [actor_input_id]
      %{actor_input_id: actor_input_id} when is_binary(actor_input_id) -> [actor_input_id]
      _ref -> []
    end)
  end

  defp request_ref_actor_input_ids(_request_refs), do: []

  defp turn_ref(%ActorInputDelivery{} = delivery) do
    %{
      "actor" => %{
        "agent_uid" => delivery.agent_uid,
        "session_id" => delivery.session_id
      },
      "activation_uid" => delivery.activation_uid,
      "actor_epoch" => delivery.actor_epoch,
      "llm_turn_id" => delivery.llm_turn_id,
      "revision" => delivery.revision
    }
  end

  defp lock_turn(repo, llm_turn_id) do
    LlmTurn
    |> where([turn], turn.id == ^llm_turn_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_conversation(repo, conversation_id) do
    Conversation
    |> where([conversation], conversation.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

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
