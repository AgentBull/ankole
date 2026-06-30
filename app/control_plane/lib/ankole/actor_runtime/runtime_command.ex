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
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
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
        with {:ok, rollover} <-
               Repo.transact(fn repo ->
                 with {:ok, stop_controls} <- end_active_conversation(repo, actor_key, input, now) do
                   {:ok, %{status: :conversation_rolled_over, stop_controls: stop_controls}}
                 end
               end)
               |> dispatch_stop_controls() do
          case TurnLifecycle.start_llm_turn(actor_key, [input], opts) do
            {:error, :no_worker_available} ->
              {:ok,
               %{
                 status: :waiting_for_worker,
                 command: input.type,
                 stop_control_outcomes: Map.get(rollover, :stop_control_outcomes, [])
               }}

            other ->
              other
          end
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
    |> dispatch_stop_controls()
    |> tap(fn
      {:ok, %{status: :command_consumed}} -> OutboxDispatcher.wake()
      _result -> :ok
    end)
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.stop"} = input, now) do
    with {:ok, stop_controls} <-
           cancel_active_generation(repo, actor_key, input, now, "command.stop"),
         {:ok, result} <- consume_command_feedback(repo, input, "Stopped.", now) do
      {:ok, Map.put(result, :stop_controls, stop_controls)}
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.new"} = input, now) do
    with {:ok, stop_controls} <- end_active_conversation(repo, actor_key, input, now),
         {:ok, result} <-
           consume_command_feedback(repo, input, "Started a new conversation.", now) do
      {:ok, Map.put(result, :stop_controls, stop_controls)}
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
    with {:ok, outbox_intents} <- command_feedback_outbox_intents(repo, input, text),
         {:ok, consumption} <-
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

  defp command_feedback_outbox_intents(_repo, %ActorInput{signal_channel_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_outbox_intents(_repo, %ActorInput{provider_entry_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_outbox_intents(repo, %ActorInput{} = input, text) do
    with {:ok, operation} <- SignalsGateway.outbox_operation_for_actor_input(input, repo) do
      command_name = String.replace_prefix(input.type, "command.", "")

      {:ok,
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
       ]}
    end
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
        live_deliveries = live_deliveries_for_generation(repo, conversation, lease_id)

        stop_controls =
          Enum.map(live_deliveries, &stop_control_for_delivery(actor_key, &1, reason))

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
             {:ok, _consumptions} <-
               consume_cancelled_turn_inputs(repo, live_deliveries, now),
             {:ok, _message} <-
               insert_command_introspection(repo, conversation, input, now, "Generation stopped.") do
          {:ok, stop_controls}
        end

      nil ->
        {:ok, []}
    end
  end

  # `/stop` fences the durable turn immediately, but the worker may still be
  # blocked in an upstream stream or tool call. The stop control is deliberately
  # best-effort and sent after commit: stale worker output is already fenced by
  # the DB, while a delivered control saves provider tokens and releases worker
  # capacity quickly.
  defp dispatch_stop_controls({:ok, result}) when is_map(result) do
    outcomes =
      result
      |> Map.get(:stop_controls, [])
      |> Enum.uniq_by(&{&1.route, &1.turn_ref})
      |> Enum.map(&dispatch_stop_control/1)

    {:ok, Map.put(result, :stop_control_outcomes, outcomes)}
  end

  defp dispatch_stop_controls(other), do: other

  defp dispatch_stop_control(%{route: route, turn_ref: turn_ref, reason: reason} = control) do
    envelope = TurnEnvelope.turn_control(turn_ref, "stop", %{"reason" => reason})

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        Map.put(control, :send_outcome, "sent_or_queued")

      {:error, reason} ->
        WorkerAdmission.mark_route_unusable(route, reason)
        control |> Map.put(:send_outcome, Atom.to_string(reason)) |> Map.put(:send_error, reason)
    end
  end

  defp live_deliveries_for_generation(_repo, _conversation, nil), do: []

  defp live_deliveries_for_generation(repo, %Conversation{} = conversation, lease_id) do
    case AIAgent.started_turn_for_lease(repo, conversation, lease_id) do
      %LlmTurn{} = turn ->
        live_deliveries_for_turn(turn, repo)

      nil ->
        []
    end
  end

  defp consume_cancelled_turn_inputs(repo, deliveries, now) when is_list(deliveries) do
    deliveries
    |> Enum.uniq_by(& &1.actor_input_id)
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, consumptions} ->
      case TurnLifecycle.lock_actor_input(repo, delivery.actor_input_id) do
        %ActorInput{} = input ->
          opts = [
            consumed_at: now,
            llm_turn_id: delivery.llm_turn_id,
            activation_uid: delivery.activation_uid,
            actor_epoch: delivery.actor_epoch,
            revision: delivery.revision
          ]

          case Actors.consume_actor_input_in_tx(repo, input, opts) do
            {:ok, consumption} -> {:cont, {:ok, [consumption | consumptions]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        nil ->
          {:cont, {:ok, consumptions}}
      end
    end)
  end

  defp live_deliveries_for_turn(%LlmTurn{} = turn, repo) do
    from(delivery in Ankole.ActorRuntime.Schemas.ActorInputDelivery,
      where: delivery.llm_turn_id == ^turn.id,
      where: delivery.state in ^ActorInputDelivery.live_states(),
      lock: "FOR UPDATE"
    )
    |> repo.all()
  end

  defp stop_control_for_delivery(actor_key, delivery, reason) do
    %{
      route: delivery.transport_route || delivery.worker_id,
      reason: reason,
      turn_ref: %{
        "actor" => %{
          "agent_uid" => actor_key.agent_uid,
          "session_id" => actor_key.session_id
        },
        "activation_uid" => delivery.activation_uid,
        "actor_epoch" => delivery.actor_epoch,
        "llm_turn_id" => delivery.llm_turn_id,
        "revision" => delivery.revision
      }
    }
  end

  defp end_active_conversation(repo, actor_key, %ActorInput{} = input, now) do
    case TurnLifecycle.active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        lease_id = TurnLifecycle.generation_lease_id(conversation.generation || %{})
        live_deliveries = live_deliveries_for_generation(repo, conversation, lease_id)

        stop_controls =
          Enum.map(live_deliveries, &stop_control_for_delivery(actor_key, &1, "command.new"))

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
             {:ok, _consumptions} <-
               consume_cancelled_turn_inputs(repo, live_deliveries, now),
             {:ok, _message} <-
               insert_command_introspection(
                 repo,
                 conversation,
                 input,
                 now,
                 "Conversation window closed."
               ) do
          {:ok, stop_controls}
        end

      nil ->
        {:ok, []}
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
