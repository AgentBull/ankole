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
  # Roles a worker may write as extra transcript rows in its proposal. Notably
  # `assistant` is excluded: the one visible answer must come only from the
  # proposal's `reply`, so there is a single source of truth for the response.
  @runtime_proposal_roles ~w(user tool im_ambient)

  @doc """
  Handles a final proposal envelope or body and commits it durably.

  The worker proposes the assistant output, but the control plane is the owner
  of durable truth. Commit writes the transcript, turn result, actor input
  consumption, and provider outbox in one database transaction.
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

  A worker error fails the current AI-agent turn and supersedes runtime
  deliveries, but it does not consume the actor input. The next scheduling pass
  can therefore retry the same user-visible work.
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

  # Makes final proposals idempotent after the durable turn has already been
  # marked succeeded. Replayed worker output must not duplicate messages or
  # outbox rows.
  defp commit_turn_in_tx(
         _repo,
         %LlmTurn{status: "succeeded"} = llm_turn,
         _turn_ref,
         _proposal,
         _now
       ) do
    {:ok, %{status: :already_committed, llm_turn: llm_turn}}
  end

  # Commits the whole user-visible response under one transaction. The order of
  # checks narrows from AI-agent lease to actor activation to delivery rows so
  # stale worker replies fail before any visible side effect is written.
  defp commit_turn_in_tx(repo, %LlmTurn{} = llm_turn, turn_ref, proposal, now) do
    with :ok <- require_turn_started(llm_turn),
         %Conversation{} = conversation <-
           AIAgent.lock_conversation(repo, llm_turn.conversation_id),
         :ok <- conversation_matches_turn(conversation, llm_turn),
         %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
         :ok <- activation_accepts_turn(activation, turn_ref, llm_turn, now),
         {:ok, deliveries} <- accepted_deliveries(repo, turn_ref),
         {:ok, actor_inputs} <- lock_delivered_actor_inputs(repo, deliveries),
         {:ok, proposed_messages} <-
           insert_proposed_runtime_messages(repo, conversation, llm_turn, proposal, now),
         {:ok, assistant_message} <-
           maybe_insert_assistant_message(
             repo,
             conversation,
             llm_turn,
             proposal,
             actor_inputs,
             now
           ),
         {:ok, llm_turn} <-
           mark_llm_turn_succeeded(
             repo,
             llm_turn,
             proposal,
             assistant_message,
             proposed_messages,
             now
           ),
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
         status: commit_status(actor_inputs, assistant_message),
         conversation: conversation,
         llm_turn: llm_turn,
         assistant_message: assistant_message,
         proposed_messages: proposed_messages,
         consumptions: consumptions
       }}
    else
      nil -> {:error, :actor_runtime_fence_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp require_turn_started(%LlmTurn{status: "started"}), do: :ok
  defp require_turn_started(%LlmTurn{}), do: {:error, :llm_turn_not_started}

  # Verifies that the conversation still grants this turn the active generation
  # lease. Cancellation or a newer lease means the worker output is stale.
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

  # Checks the activation fence and lease before accepting a final proposal. The
  # lease check lives here because final commit is the point where stale output
  # would otherwise become user-visible.
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

  # Checks the same activation fence for error handling. Errors are allowed even
  # after lease expiry because they are used to release the turn for retry.
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

  # Requires accepted delivery projections before commit. This keeps "worker got
  # the turn" explicit and prevents a direct final proposal from consuming input.
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

  # Locks exactly the open actor inputs that were accepted by the worker. Missing
  # rows mean another path consumed or canceled the input first, so commit stops.
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

  # Worker-internal handlers can propose runtime transcript rows, for example
  # the ambient handler's `im_ambient/introspection` watermark. Assistant output
  # still comes only from `reply`, so the visible answer has one source of truth.
  defp insert_proposed_runtime_messages(repo, conversation, llm_turn, proposal, now) do
    proposal
    |> fetch_list("messages")
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, index} ->
      case proposed_runtime_message_attrs(conversation, llm_turn, message, index, now) do
        {:ok, attrs} -> [%Message{} |> Message.changeset(attrs) |> repo.insert()]
        :skip -> []
      end
    end)
    |> collect_results_preserving_order()
  end

  defp proposed_runtime_message_attrs(conversation, llm_turn, proposed, index, now)
       when is_map(proposed) do
    role = fetch_text(proposed, "role")

    if role in @runtime_proposal_roles do
      metadata = fetch_map(proposed, "metadata_json") || %{}
      kind = fetch_text(metadata, "kind") || fetch_text(metadata, "message_kind") || "normal"

      {:ok,
       %{
         agent_uid: conversation.agent_uid,
         conversation_id: conversation.id,
         role: role,
         kind: kind,
         status: "complete",
         content: proposed_content(proposed),
         event_source: fetch_text(metadata, "event_source") || "agent_computer.proposal",
         event_id: fetch_text(metadata, "event_id") || "#{llm_turn.id}:#{index}",
         metadata:
           metadata
           |> Map.put_new("llm_turn_id", llm_turn.id)
           |> Map.put_new("committed_at", DateTime.to_iso8601(now))
       }}
    else
      :skip
    end
  end

  defp proposed_runtime_message_attrs(_conversation, _llm_turn, _proposed, _index, _now),
    do: :skip

  defp proposed_content(proposed) do
    case fetch_value(proposed, "content_json") do
      value when is_list(value) -> value
      value when is_binary(value) -> [%{"type" => "text", "text" => value}]
      _value -> []
    end
  end

  defp collect_results_preserving_order(results) do
    collect_results(results)
  end

  # Materializes a compression proposal as a conversation-local summary
  # checkpoint. The provider-visible side effect for the command is a fixed
  # command feedback row, not the summary body.
  defp insert_assistant_message(
         repo,
         conversation,
         %LlmTurn{kind: "compression"} = llm_turn,
         proposal,
         actor_inputs,
         now
       ) do
    input = List.first(actor_inputs)

    with {:ok, text} <- proposal_reply_text(proposal, llm_turn) do
      attrs = %{
        agent_uid: conversation.agent_uid,
        conversation_id: conversation.id,
        role: "assistant",
        kind: "summary",
        status: "complete",
        content: [%{"type" => "text", "text" => text}],
        event_source: "ai_agent.command.compress",
        event_id: input && input.ingress_event_id,
        covers_range: compression_covers_range(llm_turn),
        metadata: %{
          "actor_input_ids" => Enum.map(actor_inputs, & &1.id),
          "committed_at" => DateTime.to_iso8601(now),
          "compression" => compression_metadata(llm_turn)
        }
      }

      %Message{}
      |> Message.changeset(attrs)
      |> repo.insert()
    end
  end

  # Materializes the worker proposal as the assistant transcript message.
  defp insert_assistant_message(repo, conversation, llm_turn, proposal, actor_inputs, now) do
    with {:ok, text} <- proposal_reply_text(proposal, llm_turn),
         {:ok, attachments} <- proposal_reply_attachments(proposal) do
      attrs = %{
        agent_uid: conversation.agent_uid,
        conversation_id: conversation.id,
        role: "assistant",
        kind: "normal",
        status: "complete",
        content: assistant_content(text, attachments),
        metadata: %{
          "actor_input_ids" => Enum.map(actor_inputs, & &1.id),
          "committed_at" => DateTime.to_iso8601(now)
        }
      }

      %Message{}
      |> Message.changeset(attrs)
      |> repo.insert()
    end
  end

  defp maybe_insert_assistant_message(repo, conversation, llm_turn, proposal, actor_inputs, now) do
    case {ambient_silence_allowed?(actor_inputs), fetch_map(proposal, "reply")} do
      {true, nil} ->
        {:ok, nil}

      _other ->
        maybe_insert_visible_assistant_message(
          repo,
          conversation,
          llm_turn,
          proposal,
          actor_inputs,
          now
        )
    end
  end

  defp maybe_insert_visible_assistant_message(
         repo,
         conversation,
         llm_turn,
         proposal,
         actor_inputs,
         now
       ) do
    case proposal_reply_text(proposal, llm_turn) do
      {:ok, _text} ->
        insert_assistant_message(repo, conversation, llm_turn, proposal, actor_inputs, now)

      {:error, reason} when reason in [:proposal_reply_missing, :proposal_reply_text_missing] ->
        case ambient_silence_allowed?(actor_inputs) do
          true -> {:ok, nil}
          false -> {:error, reason}
        end
    end
  end

  defp ambient_silence_allowed?(actor_inputs) do
    actor_inputs != [] and Enum.all?(actor_inputs, &(&1.type == "im.message.may_intervene"))
  end

  # Links the LLM turn to the committed assistant message. The worker proposal
  # is kept as response metadata, not as a second source of transcript truth.
  defp mark_llm_turn_succeeded(
         repo,
         llm_turn,
         proposal,
         assistant_message,
         proposed_messages,
         now
       ) do
    response =
      %{
        "proposal" => proposal_summary(proposal),
        "proposed_message_ids" => Enum.map(proposed_messages, & &1.id)
      }
      |> maybe_put_stop_reason(proposal)
      |> maybe_put_assistant_message_id(assistant_message)

    attrs =
      %{
        status: "succeeded",
        response: response,
        completed_at: now,
        usage: proposal_usage(proposal, llm_turn),
        tool_results: proposal_tool_results(proposal),
        provider_metadata: proposal_provider_metadata(proposal, llm_turn)
      }

    llm_turn
    |> LlmTurn.changeset(attrs)
    |> repo.update()
  end

  defp maybe_put_assistant_message_id(response, %Message{id: id}),
    do: Map.put(response, "assistant_message_id", id)

  defp maybe_put_assistant_message_id(response, nil), do: response

  defp maybe_put_stop_reason(response, proposal) do
    case fetch_text(proposal, "stop_reason") do
      value when is_binary(value) and value != "" -> Map.put(response, "stop_reason", value)
      _value -> response
    end
  end

  defp commit_status(actor_inputs, nil) do
    case ambient_silence_allowed?(actor_inputs) do
      true -> :ambient_silent
      false -> :committed
    end
  end

  defp commit_status(_actor_inputs, %Message{}), do: :committed

  # Consumes each accepted actor input only after the assistant message exists.
  # This is the point where the runtime turns queued user work into completed
  # user-visible work.
  defp consume_actor_inputs(
         repo,
         actor_inputs,
         conversation,
         llm_turn,
         activation,
         assistant_message,
         now
       ) do
    ambient_post_input_id = ambient_post_input_id(actor_inputs, assistant_message)

    actor_inputs
    |> Enum.map(fn actor_input ->
      Actors.consume_actor_input_in_tx(repo, actor_input,
        conversation_id: conversation.id,
        llm_turn_id: llm_turn.id,
        activation_uid: activation.activation_uid,
        actor_epoch: activation.actor_epoch,
        revision: activation.revision,
        consumed_at: now,
        outbox_intents:
          outbox_intents(repo, actor_input, llm_turn, assistant_message, ambient_post_input_id)
      )
    end)
    |> collect_results()
  end

  defp ambient_post_input_id(actor_inputs, %Message{}) do
    case Enum.find(actor_inputs, &(&1.type == "im.message.may_intervene")) do
      %ActorInput{id: id} -> id
      nil -> nil
    end
  end

  defp ambient_post_input_id(_actor_inputs, _assistant_message), do: nil

  # Inputs without a provider-visible source cannot produce reply/update outbox
  # rows, but they can still be consumed by the durable AI-agent turn.
  defp outbox_intents(_repo, _actor_input, _llm_turn, nil, _ambient_post_input_id), do: []

  defp outbox_intents(
         _repo,
         %ActorInput{signal_channel_id: nil},
         _llm_turn,
         _assistant_message,
         _ambient_post_input_id
       ),
       do: []

  defp outbox_intents(
         _repo,
         %ActorInput{type: "im.message.may_intervene", id: id} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message,
         id
       ) do
    [
      %{
        outbound_key: "ambient:#{llm_turn.id}:#{actor_input.signal_channel_id}",
        operation: :post,
        target_provider_entry_id: nil,
        provider_thread_id: actor_input.provider_thread_id,
        payload: assistant_outbox_payload(assistant_message),
        fallback_visible_text: assistant_text(assistant_message),
        idempotency_key: "post:ambient:#{llm_turn.id}:#{actor_input.signal_channel_id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  defp outbox_intents(
         _repo,
         %ActorInput{type: "im.message.may_intervene"},
         _llm_turn,
         _assistant_message,
         _ambient_post_input_id
       ),
       do: []

  defp outbox_intents(
         _repo,
         %ActorInput{provider_entry_id: nil},
         _llm_turn,
         _assistant_message,
         _ambient_post_input_id
       ),
       do: []

  defp outbox_intents(
         repo,
         %ActorInput{type: "command.compress"} = actor_input,
         %LlmTurn{kind: "compression"} = llm_turn,
         %Message{} = assistant_message,
         _ambient_post_input_id
       ) do
    command_feedback_outbox_intents(
      repo,
      actor_input,
      llm_turn,
      assistant_message,
      "Conversation compressed."
    )
  end

  defp outbox_intents(
         _repo,
         %ActorInput{type: "command.steer"},
         _llm_turn,
         _assistant_message,
         _ambient_post_input_id
       ),
       do: []

  # Builds a provider outbox row from the committed assistant message. The
  # operation is resolved late because reply-vs-update is a signal-gateway
  # concern, not actor-runtime scheduling state.
  defp outbox_intents(
         repo,
         %ActorInput{} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message,
         _ambient_post_input_id
       ) do
    operation = SignalsGateway.outbox_operation_for_actor_input(actor_input, repo)
    operation_key = Atom.to_string(operation)

    [
      %{
        outbound_key: "llm-turn:#{llm_turn.id}:#{operation_key}:#{actor_input.id}",
        operation: operation,
        target_provider_entry_id: actor_input.provider_entry_id,
        provider_thread_id: actor_input.provider_thread_id,
        payload: assistant_outbox_payload(assistant_message),
        fallback_visible_text: assistant_text(assistant_message),
        idempotency_key: "#{operation_key}:#{llm_turn.id}:#{actor_input.id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  defp command_feedback_outbox_intents(
         repo,
         %ActorInput{} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message,
         text
       ) do
    operation = SignalsGateway.outbox_operation_for_actor_input(actor_input, repo)
    command_name = String.replace_prefix(actor_input.type, "command.", "")

    [
      %{
        outbound_key: "command:#{actor_input.id}:#{command_name}",
        operation: operation,
        target_provider_entry_id: actor_input.provider_entry_id,
        provider_thread_id: actor_input.provider_thread_id,
        payload: %{"text" => text},
        fallback_visible_text: text,
        idempotency_key: "command:#{actor_input.id}:#{command_name}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  # Deletes delivery projections after the input has been consumed. At that
  # point the consumed-input row is the durable audit of this actor work.
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

  # Supersedes all live delivery rows for a failed turn so the open actor input
  # can be selected again without seeing a live projection blocker.
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

  # Rechecks every accepted delivery against the worker's echoed turn fence.
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

  # Rejects late or cross-session worker output by comparing durable fence
  # fields instead of trusting transport order.
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

      # Revision uses `>` here, not strict `!=` as the activation/epoch fences do.
      # A worker echoes the revision it started the turn with; a steer can bump
      # the delivery's revision while the turn is still running. Rejecting only
      # when the stored revision is *newer* than the reply lets a valid final
      # proposal still commit across a concurrent steer, while a genuinely stale
      # reply (built after a newer turn took over) is still rejected by the
      # activation_uid/epoch/turn_id checks above.
      delivery.revision > fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      true ->
        :ok
    end
  end

  defp proposal_reply_text(proposal, %LlmTurn{}) do
    case fetch_map(proposal, "reply") do
      %{} = reply ->
        case fetch_text(reply, "text") do
          text when is_binary(text) ->
            case String.trim(text) do
              "" -> {:error, :proposal_reply_text_missing}
              _text -> {:ok, text}
            end

          _value ->
            {:error, :proposal_reply_text_missing}
        end

      nil ->
        {:error, :proposal_reply_missing}
    end
  end

  defp proposal_reply_attachments(proposal) do
    proposal
    |> fetch_map("reply")
    |> case do
      %{} = reply ->
        reply
        |> fetch_list("attachments")
        |> Enum.map(&normalize_reply_attachment/1)
        |> collect_results()

      _value ->
        {:ok, []}
    end
  end

  defp normalize_reply_attachment(%{} = attachment) do
    with {:ok, relative_path} <- attachment_user_files_relative_path(attachment) do
      {:ok,
       %{
         "agent_computer_path" => "/workspace/user-files/#{relative_path}",
         "user_files_relative_path" => relative_path
       }
       |> maybe_put("name", optional_text_field(attachment, "name"))
       |> maybe_put("mime_type", optional_text_field(attachment, "mime_type"))
       |> maybe_put("xxh3_128", optional_text_field(attachment, "xxh3_128"))
       |> maybe_put("size", optional_non_negative_integer(attachment, "size"))}
    end
  end

  defp normalize_reply_attachment(_attachment), do: {:error, :invalid_reply_attachment}

  defp attachment_user_files_relative_path(attachment) do
    path =
      optional_text_field(attachment, "user_files_relative_path") ||
        optional_text_field(attachment, "agent_computer_path") ||
        optional_text_field(attachment, "path")

    cond do
      is_binary(path) and String.starts_with?(path, "/workspace/user-files/") ->
        normalize_user_files_relative_path(
          String.replace_prefix(path, "/workspace/user-files/", "")
        )

      is_binary(path) ->
        normalize_user_files_relative_path(path)

      true ->
        {:error, :reply_attachment_path_missing}
    end
  end

  defp normalize_user_files_relative_path(path) do
    normalized =
      path
      |> String.replace("\\", "/")
      |> String.replace(~r{/+}, "/")
      |> String.trim_leading("/")

    segments = String.split(normalized, "/", trim: true)

    case segments != [] and Enum.all?(segments, &valid_relative_segment?/1) do
      true -> {:ok, Enum.join(segments, "/")}
      false -> {:error, :invalid_reply_attachment_path}
    end
  end

  defp valid_relative_segment?(segment), do: segment not in ["", ".", ".."]

  defp optional_text_field(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp optional_non_negative_integer(map, key) do
    case fetch_value(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> nil
    end
  end

  defp assistant_content(text, attachments) do
    [%{"type" => "text", "text" => text}] ++
      Enum.map(attachments, &Map.put(&1, "type", "attachment"))
  end

  defp assistant_outbox_payload(%Message{} = message) do
    %{"text" => assistant_text(message)}
    |> maybe_put("attachments", assistant_attachments(message))
  end

  defp assistant_attachments(%Message{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "attachment"} = attachment -> [Map.delete(attachment, "type")]
      _part -> []
    end)
  end

  defp assistant_attachments(_message), do: []

  defp proposal_summary(proposal) do
    %{
      "reply" => fetch_map(proposal, "reply") || %{},
      "messages" => fetch_list(proposal, "messages")
    }
  end

  defp proposal_usage(proposal, %LlmTurn{usage: usage}) do
    case fetch_map(proposal, "usage_json") do
      %{} = usage -> usage
      _value -> usage || %{}
    end
  end

  defp proposal_tool_results(proposal) do
    fetch_list(proposal, "tool_results_json")
  end

  defp proposal_provider_metadata(proposal, %LlmTurn{provider_metadata: provider_metadata}) do
    provider_metadata = provider_metadata || %{}

    case fetch_map(proposal, "provider_metadata_json") do
      %{} = proposal_metadata -> Map.merge(provider_metadata, proposal_metadata)
      _value -> provider_metadata
    end
  end

  defp compression_covers_range(%LlmTurn{input_message_ids: [first_id | _] = message_ids}) do
    %{
      "first_message_id" => first_id,
      "last_message_id" => List.last(message_ids)
    }
  end

  defp compression_covers_range(_llm_turn), do: %{}

  defp compression_metadata(%LlmTurn{} = llm_turn) do
    compression = fetch_map(llm_turn.request_context || %{}, "compression") || %{}

    %{
      "trigger" => fetch_text(compression, "trigger") || "manual_command",
      "llm_turn_ids" => [llm_turn.id],
      "first_kept_message_id" => fetch_text(compression, "first_kept_message_id"),
      "tokens_before" => Map.get(compression, "tokens_before"),
      "strategy" => "light_model"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Normalizes worker error payloads into the shape stored on failed turns and
  # superseded deliveries.
  defp worker_turn_error(payload) do
    %{
      code: fetch_text(payload, "code") || "worker_turn_error",
      message: fetch_text(payload, "message") || "worker turn failed",
      details: fetch_map(payload, "details_json") || %{}
    }
  end

  defp assistant_text(%Message{content: [%{"text" => text} | _]}) when is_binary(text), do: text
  defp assistant_text(_message), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp fetch_value(map, key) when is_map(map) do
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
