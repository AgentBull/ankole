defmodule Ankole.ActorRuntime.RuntimeCommand do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.TurnEnvelope
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.ActorRuntime.TurnRetry
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.Repo
  alias Ankole.SignalsGateway

  def process_new_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case command_args(input) do
      "" ->
        process_runtime_command(actor_key, input, opts)

      _args ->
        with {:ok, _result} <-
               Repo.transact(fn repo ->
                 with :ok <- end_active_conversation(repo, actor_key, input, now) do
                   {:ok, %{status: :conversation_rolled_over}}
                 end
               end) do
          TurnLifecycle.start_llm_turn(actor_key, [input], opts)
        end
    end
  end

  def process_runtime_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = input <- TurnLifecycle.lock_actor_input(repo, input.id),
           {:ok, result} <- apply_runtime_command(repo, actor_key, input, now) do
        {:ok, result}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
    |> TurnRetry.dispatch_retry_controls()
    |> tap(fn
      {:ok, %{status: :command_consumed}} -> OutboxDispatcher.wake()
      _result -> :ok
    end)
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.stop"} = input, now) do
    with :ok <- cancel_active_generation(repo, actor_key, input, now, "command.stop") do
      consume_command_feedback(repo, input, "Stopped.", now)
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.new"} = input, now) do
    with :ok <- end_active_conversation(repo, actor_key, input, now) do
      consume_command_feedback(repo, input, "Started a new conversation.", now)
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.retry"} = input, now) do
    case TurnRetry.retry_active_generation_in_tx(repo, actor_key, input, now) do
      {:ok, :no_active_generation} ->
        with {:ok, retry_input} <- append_retry_input(repo, actor_key, input, now),
             {:ok, consumption} <- consume_command_without_feedback(repo, input, now) do
          {:ok,
           %{
             status: :command_consumed,
             command: input.type,
             retry_actor_input: retry_input,
             consumption: consumption
           }}
        end

      {:ok, %{status: :command_consumed} = result} ->
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_runtime_command(repo, _actor_key, %ActorInput{type: "command.steer"} = input, now) do
    consume_command_feedback(repo, input, "Steer requires instructions.", now)
  end

  def process_steer_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case command_args(input) do
      "" ->
        process_runtime_command(actor_key, input, opts)

      _args ->
        Repo.transact(fn repo ->
          with %ActorInput{} = input <- TurnLifecycle.lock_actor_input(repo, input.id) do
            case TurnLifecycle.active_generation?(repo, actor_key) do
              true ->
                prepare_active_steer(repo, actor_key, input, now)

              false ->
                {:ok, %{status: :steer_as_generation}}
            end
          else
            nil -> {:ok, %{status: :idle}}
            {:error, _reason} = error -> error
          end
        end)
        |> case do
          {:ok, %{status: :steer_as_generation}} ->
            TurnLifecycle.start_llm_turn(actor_key, [input], opts)

          {:ok, %{status: :active_steer_nudged} = result} ->
            send_mailbox_updated(result)

          other ->
            other
        end
    end
  end

  defp prepare_active_steer(repo, actor_key, %ActorInput{} = input, now) do
    case TurnLifecycle.live_delivery_for_input?(repo, input.id) do
      true ->
        {:ok, %{status: :waiting_for_generation, command: input.type}}

      false ->
        with %Conversation{} = conversation <-
               TurnLifecycle.active_conversation_for_update(repo, actor_key),
             true <- TurnLifecycle.conversation_has_active_generation?(conversation),
             %ActorSessionActivation{} = activation <-
               TurnLifecycle.live_activation(repo, actor_key),
             true <- TurnLifecycle.activation_lease_alive?(activation, now),
             %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, activation.current_llm_turn_id),
             %ActorSessionWorkerAssignment{} = assignment <-
               TurnLifecycle.live_assignment(repo, actor_key),
             {:ok, activation} <- TurnLifecycle.bump_activation_revision(repo, activation, now),
             {:ok, _message} <-
               insert_command_introspection(
                 repo,
                 conversation,
                 input,
                 now,
                 "Steering note received: #{command_args(input)}"
               ),
             {:ok, delivery} <-
               TurnLifecycle.create_input_delivery_in_tx(
                 repo,
                 input,
                 activation,
                 llm_turn,
                 assignment.transport_route || assignment.worker_id,
                 assignment,
                 now
               ),
             {:ok, delivery} <-
               TurnLifecycle.mark_delivery_sent_in_tx(repo, delivery, now, "sent_or_queued") do
          {:ok,
           %{
             status: :active_steer_nudged,
             command: input.type,
             activation: activation,
             assignment: assignment,
             delivery: delivery,
             input: input,
             turn_ref: TurnEnvelope.turn_ref(repo, actor_key, activation, llm_turn)
           }}
        else
          false -> {:ok, %{status: :waiting_for_generation, command: input.type}}
          nil -> {:error, :active_turn_not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  defp send_mailbox_updated(
         %{
           assignment: assignment,
           delivery: delivery,
           input: input,
           turn_ref: turn_ref
         } = result
       ) do
    route = assignment.transport_route || assignment.worker_id
    envelope = TurnEnvelope.mailbox_updated(turn_ref, [input])

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        {:ok, Map.put(result, :send_outcome, "sent_or_queued")}

      {:error, reason} ->
        TurnLifecycle.mark_delivery_failed(delivery.id, reason, reason)
        WorkerAdmission.mark_route_unusable(route, reason)
        {:ok, Map.put(result, :send_outcome, Atom.to_string(reason))}
    end
  end

  defp consume_command_feedback(repo, %ActorInput{} = input, text, now) do
    outbox_intents = command_feedback_outbox_intents(repo, input, text)

    with {:ok, consumption} <-
           Actors.consume_command_input_in_tx(repo, input,
             consumed_at: now,
             outbox_intents: outbox_intents
           ) do
      {:ok,
       %{
         status: :command_consumed,
         command: input.type,
         feedback: text,
         consumption: consumption
       }}
    end
  end

  defp consume_command_without_feedback(repo, %ActorInput{} = input, now) do
    Actors.consume_command_input_in_tx(repo, input,
      consumed_at: now,
      outbox_intents: []
    )
  end

  defp command_feedback_outbox_intents(_repo, %ActorInput{signal_channel_id: nil}, _text), do: []
  defp command_feedback_outbox_intents(_repo, %ActorInput{provider_entry_id: nil}, _text), do: []

  defp command_feedback_outbox_intents(repo, %ActorInput{} = input, text) do
    operation = SignalsGateway.outbox_operation_for_actor_input(input, repo)
    command_name = String.replace_prefix(input.type, "command.", "")

    [
      %{
        outbound_key: "command:#{input.id}:#{command_name}",
        operation: operation,
        target_provider_entry_id: input.provider_entry_id,
        provider_thread_id: input.provider_thread_id,
        payload: %{"text" => text},
        fallback_visible_text: text,
        idempotency_key: "command:#{input.id}:#{command_name}"
      }
    ]
  end

  defp append_retry_input(repo, actor_key, %ActorInput{} = command_input, now) do
    with %Conversation{} = conversation <-
           TurnLifecycle.active_conversation_for_update(repo, actor_key),
         {:ok, retry_source} <- retry_source(repo, conversation) do
      Actors.append_actor_input_in_tx(repo, %{
        agent_uid: command_input.agent_uid,
        binding_name: command_input.binding_name,
        session_id: command_input.session_id,
        ingress_event_id: "retry:#{command_input.id}",
        signal_channel_id: command_input.signal_channel_id,
        provider_thread_id: command_input.provider_thread_id,
        provider_entry_id: command_input.provider_entry_id,
        type: "im.message.receive",
        available_at: now,
        sender_key: command_input.sender_key,
        payload: %{
          "type" => "im.message.receive",
          "data" => %{
            "entry" => %{
              "text" => retry_source.text,
              "retry_of_llm_turn_id" => retry_source.llm_turn_id,
              "retry_of_message_id" => retry_source.message_id
            }
          }
        }
      })
    else
      nil -> {:error, :conversation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp retry_source(repo, %Conversation{} = conversation) do
    last_turn =
      LlmTurn
      |> where([turn], turn.conversation_id == ^conversation.id)
      |> where([turn], turn.kind in ["generation", "retry_generation"])
      |> where([turn], turn.status in ["succeeded", "failed", "cancelled"])
      |> order_by([turn], desc: turn.started_at, desc: turn.inserted_at)
      |> repo.one()

    case last_turn do
      %LlmTurn{input_message_ids: [message_id | _]} = turn ->
        case repo.get(Message, message_id) do
          %Message{} = message ->
            {:ok,
             %{
               llm_turn_id: turn.id,
               message_id: message.id,
               text: message_text(message)
             }}

          nil ->
            {:error, :retry_source_message_not_found}
        end

      %LlmTurn{} ->
        {:error, :retry_source_message_not_found}

      nil ->
        {:error, :retry_source_not_found}
    end
  end

  defp message_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp message_text(_message), do: ""

  defp cancel_active_generation(repo, actor_key, %ActorInput{} = input, now, reason) do
    case TurnLifecycle.active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        lease_id = TurnLifecycle.generation_lease_id(conversation.generation || %{})
        generation = TurnLifecycle.cancel_generation(conversation.generation || %{}, now, reason)

        with {:ok, conversation} <-
               conversation
               |> Conversation.changeset(%{generation: generation})
               |> repo.update(),
             {:ok, _cancelled_turn} <-
               TurnLifecycle.cancel_started_turn_for_lease(
                 repo,
                 conversation,
                 lease_id,
                 now,
                 reason
               ),
             {:ok, _message} <-
               insert_command_introspection(repo, conversation, input, now, "Generation stopped.") do
          :ok
        end

      nil ->
        :ok
    end
  end

  defp end_active_conversation(repo, actor_key, %ActorInput{} = input, now) do
    case TurnLifecycle.active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        lease_id = TurnLifecycle.generation_lease_id(conversation.generation || %{})

        generation =
          TurnLifecycle.cancel_generation(conversation.generation || %{}, now, "command.new")

        with {:ok, conversation} <-
               conversation
               |> Conversation.changeset(%{generation: generation, ended_at: now})
               |> repo.update(),
             {:ok, _cancelled_turn} <-
               TurnLifecycle.cancel_started_turn_for_lease(
                 repo,
                 conversation,
                 lease_id,
                 now,
                 "command.new"
               ),
             {:ok, _message} <-
               insert_command_introspection(
                 repo,
                 conversation,
                 input,
                 now,
                 "Conversation window closed."
               ) do
          :ok
        end

      nil ->
        :ok
    end
  end

  defp insert_command_introspection(
         repo,
         %Conversation{} = conversation,
         %ActorInput{} = input,
         now,
         text
       ) do
    %Message{}
    |> Message.changeset(%{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: "assistant",
      kind: "introspection",
      status: "complete",
      content: [%{"type" => "text", "text" => text}],
      event_source: "ai_agent.#{input.type}",
      event_id: input.ingress_event_id,
      metadata: %{
        "actor_input_id" => input.id,
        "command" => input.type,
        "command_args" => command_args(input),
        "inserted_at" => DateTime.to_iso8601(now)
      }
    })
    |> repo.insert()
  end

  defp command_args(%ActorInput{payload: payload}) when is_map(payload) do
    payload
    |> get_in(["data", "command", "argsText"])
    |> case do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp command_args(_input), do: ""
end
