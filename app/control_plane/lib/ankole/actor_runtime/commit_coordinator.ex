defmodule Ankole.ActorRuntime.CommitCoordinator do
  @moduledoc """
  Final proposal commit boundary.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.Repo
  alias Ankole.SignalsGateway

  @live_delivery_states ~w(created sent accepted)

  @doc """
  Handles a final proposal envelope or body and commits it durably.
  """
  @spec commit_final_proposal(map()) :: {:ok, map()} | {:error, term()}
  def commit_final_proposal(proposal) when is_map(proposal) do
    proposal = unwrap_body(proposal, "turn_final_proposal")
    turn_ref = fetch_map!(proposal, "turn")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, fetch_turn_id(turn_ref)),
           {:ok, result} <- commit_turn_in_tx(repo, llm_turn, turn_ref, proposal, now) do
        {:ok, result}
      else
        nil -> {:error, :llm_turn_not_found}
        {:error, _reason} = error -> error
      end
    end)
    |> tap(fn
      {:ok, %{status: :committed}} -> OutboxDispatcher.wake()
      _result -> :ok
    end)
  end

  @doc """
  Handles a worker turn.error envelope and releases the actor input for retry.
  """
  @spec handle_turn_error(map()) :: {:ok, map()} | {:error, term()}
  def handle_turn_error(envelope) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_error")
    turn_ref = fetch_map!(payload, "turn")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, fetch_turn_id(turn_ref)),
           :ok <- require_turn_started(llm_turn),
           %Conversation{} = conversation <-
             AIAgent.lock_conversation(repo, llm_turn.conversation_id),
           %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
           :ok <- activation_matches_turn(activation, turn_ref, llm_turn),
           {:ok, failed_turn} <-
             AIAgent.fail_turn_in_tx(repo, llm_turn, worker_turn_error(payload), now),
           {:ok, conversation} <-
             AIAgent.clear_generation_in_tx(repo, conversation, failed_turn.lease_id),
           {superseded_count, _rows} <-
             supersede_turn_deliveries(repo, turn_ref, now, worker_turn_error(payload)),
           {:ok, activation} <- fail_activation(repo, activation, worker_turn_error(payload), now) do
        {:ok,
         %{
           status: :turn_failed,
           conversation: conversation,
           llm_turn: failed_turn,
           activation: activation,
           superseded_deliveries: superseded_count
         }}
      else
        nil -> {:error, :actor_runtime_fence_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp commit_turn_in_tx(
         _repo,
         %LlmTurn{status: "succeeded"} = llm_turn,
         _turn_ref,
         _proposal,
         _now
       ) do
    {:ok, %{status: :already_committed, llm_turn: llm_turn}}
  end

  defp commit_turn_in_tx(repo, %LlmTurn{} = llm_turn, turn_ref, proposal, now) do
    with :ok <- require_turn_started(llm_turn),
         %Conversation{} = conversation <-
           AIAgent.lock_conversation(repo, llm_turn.conversation_id),
         :ok <- conversation_matches_turn(conversation, llm_turn),
         %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
         :ok <- activation_accepts_turn(activation, turn_ref, llm_turn, now),
         {:ok, deliveries} <- accepted_deliveries(repo, turn_ref),
         {:ok, actor_inputs} <- lock_delivered_actor_inputs(repo, deliveries),
         {:ok, assistant_message} <-
           insert_assistant_message(repo, conversation, proposal, actor_inputs, now),
         {:ok, llm_turn} <-
           mark_llm_turn_succeeded(repo, llm_turn, proposal, assistant_message, now),
         {:ok, consumptions} <-
           consume_actor_inputs(
             repo,
             actor_inputs,
             conversation,
             llm_turn,
             activation,
             assistant_message,
             now
           ),
         {_, _} <- delete_deliveries(repo, actor_inputs),
         {:ok, conversation} <-
           AIAgent.clear_generation_in_tx(repo, conversation, llm_turn.lease_id) do
      {:ok,
       %{
         status: :committed,
         conversation: conversation,
         llm_turn: llm_turn,
         assistant_message: assistant_message,
         consumptions: consumptions
       }}
    else
      nil -> {:error, :actor_runtime_fence_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp require_turn_started(%LlmTurn{status: "started"}), do: :ok
  defp require_turn_started(%LlmTurn{}), do: {:error, :llm_turn_not_started}

  defp conversation_matches_turn(%Conversation{generation: generation}, %LlmTurn{
         lease_id: lease_id
       })
       when is_map(generation) do
    case generation["lease_id"] == lease_id and is_nil(generation["cancelled_at"]) do
      true -> :ok
      false -> {:error, :generation_lease_mismatch}
    end
  end

  defp conversation_matches_turn(_conversation, _turn), do: {:error, :generation_lease_mismatch}

  defp activation_accepts_turn(%ActorSessionActivation{} = activation, turn_ref, llm_turn, now) do
    cond do
      activation.agent_uid != fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      activation.session_id != fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      activation.activation_uid != fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      activation.revision != fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      activation.current_llm_turn_id != llm_turn.id ->
        {:error, :stale_llm_turn_id}

      DateTime.compare(activation.lease_expires_at, now) != :gt ->
        {:error, :activation_lease_expired}

      true ->
        :ok
    end
  end

  defp activation_matches_turn(%ActorSessionActivation{} = activation, turn_ref, llm_turn) do
    cond do
      activation.agent_uid != fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      activation.session_id != fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      activation.activation_uid != fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      activation.revision != fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      activation.current_llm_turn_id != llm_turn.id ->
        {:error, :stale_llm_turn_id}

      true ->
        :ok
    end
  end

  defp accepted_deliveries(repo, turn_ref) do
    llm_turn_id = fetch_turn_id(turn_ref)

    deliveries =
      ActorInputDelivery
      |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
      |> where([delivery], delivery.state == "accepted")
      |> lock("FOR UPDATE")
      |> repo.all()

    case deliveries do
      [] ->
        {:error, :no_accepted_delivery}

      deliveries ->
        deliveries
        |> validate_deliveries_turn_ref(turn_ref)
        |> case do
          :ok -> {:ok, deliveries}
          {:error, _reason} = error -> error
        end
    end
  end

  defp lock_delivered_actor_inputs(repo, deliveries) do
    input_ids = Enum.map(deliveries, & &1.actor_input_id)

    actor_inputs =
      ActorInput
      |> where([input], input.id in ^input_ids)
      |> where([input], input.input_state == "open")
      |> order_by([input], asc: input.broker_sequence)
      |> lock("FOR UPDATE")
      |> repo.all()

    case MapSet.new(Enum.map(actor_inputs, & &1.id)) == MapSet.new(input_ids) do
      true -> {:ok, actor_inputs}
      false -> {:error, :actor_input_not_open}
    end
  end

  defp insert_assistant_message(repo, conversation, proposal, actor_inputs, now) do
    text = proposal_reply_text(proposal)

    attrs = %{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: "assistant",
      kind: "normal",
      status: "complete",
      content: [%{"type" => "text", "text" => text}],
      metadata: %{
        "actor_input_ids" => Enum.map(actor_inputs, & &1.id),
        "committed_at" => DateTime.to_iso8601(now),
        "placeholder" => true
      }
    }

    %Message{}
    |> Message.changeset(attrs)
    |> repo.insert()
  end

  defp mark_llm_turn_succeeded(repo, llm_turn, proposal, assistant_message, now) do
    response = %{
      "proposal" => proposal_summary(proposal),
      "assistant_message_id" => assistant_message.id
    }

    llm_turn
    |> LlmTurn.changeset(%{status: "succeeded", response: response, completed_at: now})
    |> repo.update()
  end

  defp consume_actor_inputs(
         repo,
         actor_inputs,
         conversation,
         llm_turn,
         activation,
         assistant_message,
         now
       ) do
    actor_inputs
    |> Enum.map(fn actor_input ->
      Actors.consume_actor_input_in_tx(repo, actor_input,
        conversation_id: conversation.id,
        llm_turn_id: llm_turn.id,
        activation_uid: activation.activation_uid,
        actor_epoch: activation.actor_epoch,
        revision: activation.revision,
        consumed_at: now,
        outbox_intents: outbox_intents(repo, actor_input, llm_turn, assistant_message)
      )
    end)
    |> collect_results()
  end

  defp outbox_intents(_repo, %ActorInput{signal_channel_id: nil}, _llm_turn, _assistant_message),
    do: []

  defp outbox_intents(_repo, %ActorInput{provider_entry_id: nil}, _llm_turn, _assistant_message),
    do: []

  defp outbox_intents(
         repo,
         %ActorInput{} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message
       ) do
    operation = SignalsGateway.outbox_operation_for_actor_input(actor_input, repo)
    operation_key = Atom.to_string(operation)

    [
      %{
        outbound_key: "llm-turn:#{llm_turn.id}:#{operation_key}:#{actor_input.id}",
        operation: operation,
        target_provider_entry_id: actor_input.provider_entry_id,
        provider_thread_id: actor_input.provider_thread_id,
        payload: %{"text" => assistant_text(assistant_message)},
        fallback_visible_text: assistant_text(assistant_message),
        idempotency_key: "#{operation_key}:#{llm_turn.id}:#{actor_input.id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  defp delete_deliveries(repo, actor_inputs) do
    input_ids = Enum.map(actor_inputs, & &1.id)

    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id in ^input_ids)
    |> repo.delete_all()
  end

  defp activation_for_turn_ref(repo, turn_ref) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^fetch_actor_agent_uid(turn_ref))
    |> where([activation], activation.session_id == ^fetch_actor_session_id(turn_ref))
    |> where([activation], activation.activation_uid == ^fetch_text!(turn_ref, "activation_uid"))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp fail_activation(repo, %ActorSessionActivation{} = activation, reason, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "failed",
      current_llm_turn_id: nil,
      stopped_at: now,
      stop_reason: inspect(reason)
    })
    |> repo.update()
  end

  defp supersede_turn_deliveries(repo, turn_ref, now, reason) do
    turn_ref
    |> fetch_turn_id()
    |> supersede_turn_deliveries_by_id(repo, now, reason)
  end

  defp supersede_turn_deliveries_by_id(llm_turn_id, repo, now, reason) do
    ActorInputDelivery
    |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

  defp validate_deliveries_turn_ref(deliveries, turn_ref) do
    Enum.reduce_while(deliveries, :ok, fn
      delivery, :ok ->
        case delivery_matches_turn_ref(delivery, turn_ref) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _delivery, {:error, _reason} = error ->
        {:halt, error}
    end)
  end

  defp delivery_matches_turn_ref(%ActorInputDelivery{} = delivery, turn_ref) do
    cond do
      delivery.agent_uid != fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      delivery.session_id != fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      delivery.activation_uid != fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      delivery.actor_epoch != fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      delivery.llm_turn_id != fetch_turn_id(turn_ref) ->
        {:error, :stale_llm_turn_id}

      delivery.revision != fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      true ->
        :ok
    end
  end

  defp proposal_reply_text(proposal) do
    case fetch_map(proposal, "reply") do
      %{} = reply -> fetch_text(reply, "text") || "PONG"
      nil -> "PONG"
    end
  end

  defp proposal_summary(proposal) do
    %{
      "reply" => fetch_map(proposal, "reply") || %{},
      "messages" => fetch_list(proposal, "messages")
    }
  end

  defp worker_turn_error(payload) do
    %{
      code: fetch_text(payload, "code") || "worker_turn_error",
      message: fetch_text(payload, "message") || "worker turn failed",
      details: fetch_map(payload, "details_json") || %{}
    }
  end

  defp assistant_text(%Message{content: [%{"text" => text} | _]}) when is_binary(text), do: text
  defp assistant_text(_message), do: "PONG"

  defp unwrap_body(%{"body" => %{"type" => type} = body}, type), do: fetch_map!(body, type)
  defp unwrap_body(%{body: %{"type" => type} = body}, type), do: fetch_map!(body, type)
  defp unwrap_body(%{body: %{type: type} = body}, type), do: fetch_map!(body, type)

  defp unwrap_body(%{} = map, type),
    do: fetch_map(map, type) || fetch_map(map, String.to_atom(type)) || map

  defp fetch_actor_agent_uid(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("agent_uid") |> normalize_uid()

  defp fetch_actor_session_id(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("session_id")

  defp fetch_turn_id(turn_ref), do: fetch_text!(turn_ref, "llm_turn_id")

  defp fetch_text!(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  defp fetch_text(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_map!(map, key) do
    case fetch_map(map, key) do
      %{} = value -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  defp fetch_map(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)

  defp fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp fetch_int!(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

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
end
