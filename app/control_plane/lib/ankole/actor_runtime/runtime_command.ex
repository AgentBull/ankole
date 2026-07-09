defmodule Ankole.ActorRuntime.RuntimeCommand do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.TurnEnvelope
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.ActorRuntime.TurnRetry
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AIReplyPreview

  def process_new_command(actor_key, %ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case command_args(input) do
      "" ->
        process_runtime_command(actor_key, input, opts)

      _args ->
        with {:ok, rollover} <-
               Repo.transact(fn repo ->
                 with {:ok, %{stop_controls: stop_controls, cancelled_turn: cancelled_turn}} <-
                        end_active_conversation(repo, actor_key, now) do
                   {:ok,
                    %{
                      status: :conversation_rolled_over,
                      stop_controls: stop_controls,
                      cancelled_turn: cancelled_turn
                    }}
                 end
               end)
               |> publish_cancelled_turn_event()
               |> dispatch_stop_controls() do
          case TurnLifecycle.start_worker_turn(actor_key, input, opts) do
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

  def process_runtime_command(actor_key, %ActorEvent{type: "command.compress"} = input, opts) do
    process_compress_command(actor_key, input, opts)
  end

  def process_runtime_command(actor_key, %ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- TurnLifecycle.lock_actor_event(repo, input.id),
           {:ok, result} <- apply_runtime_command(repo, actor_key, input, now) do
        {:ok, result}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
    |> publish_cancelled_turn_event()
    |> maybe_start_retry_preview()
    |> TurnRetry.dispatch_retry_controls()
    |> dispatch_stop_controls()
  end

  @doc false
  def process_subagent_stop(actor_key, %ActorEvent{type: "command.stop"} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- TurnLifecycle.lock_actor_event(repo, input.id),
           {:ok, %{stop_controls: stop_controls, cancelled_turn: cancelled_turn}} <-
             cancel_live_turn(repo, actor_key, now, "command.stop"),
           {:ok, completed_event} <- consume_command_without_feedback(repo, input, now) do
        {:ok,
         %{
           status: :command_consumed,
           command: input.type,
           actor_event: completed_event,
           stop_controls: stop_controls,
           cancelled_turn: cancelled_turn
         }}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
    |> publish_cancelled_turn_event()
    |> dispatch_stop_controls()
  end

  defp process_compress_command(actor_key, %ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, %{actor_event: input, conversation: conversation}} <-
           prepare_compress_command(actor_key, input, now),
         {:ok, %{compaction: compaction}} <-
           Compaction.compact_conversation(input.agent_uid, conversation.id, %{
             "metadata" => %{
               "actor_event_id" => input.id,
               "command" => input.type,
               "command_args" => command_args(input)
             }
           }),
         {:ok, result} <- consume_compress_command(input, compaction, now) do
      {:ok, result}
    else
      {:ok, %{status: _status}} = ok -> ok
      {:error, :no_compaction_candidate} -> consume_compress_noop(input, now)
      {:error, _reason} = error -> error
    end
  end

  defp prepare_compress_command(actor_key, %ActorEvent{} = input, now) do
    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- TurnLifecycle.lock_actor_event(repo, input.id),
           false <- session_has_running_ai_work?(repo, actor_key) do
        case TurnLifecycle.active_conversation_for_update(repo, actor_key) do
          %Conversation{} = conversation ->
            {:ok, %{actor_event: input, conversation: conversation}}

          nil ->
            consume_command_feedback(repo, input, "No conversation to compress.", now)
        end
      else
        nil -> {:ok, %{status: :idle}}
        true -> {:ok, %{status: :waiting_for_generation, command: input.type, actor_event: input}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp session_has_running_ai_work?(repo, actor_key) do
    TurnLifecycle.session_has_running_work?(repo, actor_key) or
      session_has_generating_response?(repo, actor_key)
  end

  defp session_has_generating_response?(repo, actor_key) do
    Message
    |> join(:inner, [message], conversation in Conversation,
      on: conversation.id == message.conversation_id
    )
    |> where([message, conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([_message, conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([_message, conversation], is_nil(conversation.ended_at))
    |> where([message, _conversation], message.type == "message")
    |> where([message, _conversation], message.status == "generating")
    |> repo.exists?()
  end

  defp consume_compress_command(%ActorEvent{} = input, %Message{} = compaction, now) do
    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- TurnLifecycle.lock_actor_event(repo, input.id),
           {:ok, outbox_intents} <-
             command_feedback_outbox_intents(repo, input, "Conversation compressed."),
           outbox_intents =
             Enum.map(outbox_intents, &Map.put(&1, :ai_message_id, compaction.id)),
           {:ok, completed_event} <-
             Actors.complete_command_event_in_tx(repo, input,
               completed_at: now,
               outbox_intents: outbox_intents
             ) do
        {:ok,
         %{
           status: :command_consumed,
           command: input.type,
           feedback: "Conversation compressed.",
           message: compaction,
           actor_event: completed_event
         }}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp consume_compress_noop(%ActorEvent{} = input, now) do
    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- TurnLifecycle.lock_actor_event(repo, input.id) do
        consume_command_feedback(repo, input, "Nothing to compress.", now)
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp apply_runtime_command(repo, actor_key, %ActorEvent{type: "command.stop"} = input, now) do
    with {:ok, %{stop_controls: stop_controls, cancelled_turn: cancelled_turn}} <-
           cancel_live_turn(repo, actor_key, now, "command.stop"),
         {:ok, result} <- consume_command_feedback(repo, input, "Stopped.", now) do
      {:ok,
       result
       |> Map.put(:stop_controls, stop_controls)
       |> Map.put(:cancelled_turn, cancelled_turn)}
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorEvent{type: "command.new"} = input, now) do
    with {:ok, %{stop_controls: stop_controls, cancelled_turn: cancelled_turn}} <-
           end_active_conversation(repo, actor_key, now),
         {:ok, result} <-
           consume_command_feedback(repo, input, "Started a new conversation.", now) do
      {:ok,
       result
       |> Map.put(:stop_controls, stop_controls)
       |> Map.put(:cancelled_turn, cancelled_turn)}
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorEvent{type: "command.retry"} = input, now) do
    case TurnRetry.retry_live_turn_in_tx(repo, actor_key, input, now) do
      {:ok, :no_live_turn} ->
        with {:ok, retry_event} <- append_retry_event(repo, actor_key, input, now),
             {:ok, completed_event} <- consume_command_without_feedback(repo, input, now) do
          {:ok,
           %{
             status: :command_consumed,
             command: input.type,
             retry_actor_event: retry_event,
             actor_event: completed_event
           }}
        end

      {:ok, %{status: :command_consumed} = result} ->
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_runtime_command(repo, _actor_key, %ActorEvent{type: "command.steer"} = input, now) do
    consume_command_feedback(repo, input, "Steer requires instructions.", now)
  end

  def process_steer_command(actor_key, %ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case command_args(input) do
      "" ->
        process_runtime_command(actor_key, input, opts)

      _args ->
        Repo.transact(fn repo ->
          with %ActorEvent{} = input <- TurnLifecycle.lock_actor_event(repo, input.id) do
            case TurnLifecycle.live_delivery_for_session?(repo, actor_key) do
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
            TurnLifecycle.start_worker_turn(actor_key, input, opts)

          {:ok, %{status: :active_steer_nudged} = result} ->
            send_mailbox_updated(result)

          other ->
            other
        end
    end
  end

  defp prepare_active_steer(repo, actor_key, %ActorEvent{} = input, now) do
    case TurnLifecycle.live_delivery_for_event?(repo, input.id) do
      true ->
        {:ok, %{status: :waiting_for_generation, command: input.type}}

      false ->
        with %ActorSessionActivation{} = activation <-
               TurnLifecycle.live_activation(repo, actor_key),
             true <- TurnLifecycle.activation_lease_alive?(activation, now),
             :open <- current_activation_event_state(repo, actor_key, activation),
             %ActorSessionWorkerAssignment{} = assignment <-
               TurnLifecycle.live_assignment(repo, actor_key),
             {:ok, activation} <- TurnLifecycle.bump_activation_revision(repo, activation, now),
             {:ok, delivery} <-
               TurnLifecycle.create_event_delivery_in_tx(
                 repo,
                 input,
                 activation,
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
             actor_event: input,
             activation: activation,
             assignment: assignment,
             delivery: delivery,
             completed_at: now,
             turn_ref: TurnEnvelope.turn_ref(actor_key, activation)
           }}
        else
          false -> {:ok, %{status: :waiting_for_generation, command: input.type}}
          state when state in [:completed, :missing] -> {:ok, %{status: :steer_as_generation}}
          nil -> {:error, :active_turn_not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  defp current_activation_event_state(
         repo,
         actor_key,
         %ActorSessionActivation{current_actor_event_id: actor_event_id}
       )
       when is_binary(actor_event_id) do
    ActorEvent
    |> where([event], event.id == ^actor_event_id)
    |> where([event], event.agent_uid == ^actor_key.agent_uid)
    |> where([event], event.session_id == ^actor_key.session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %ActorEvent{completed_at: nil} -> :open
      %ActorEvent{} -> :completed
      nil -> :missing
    end
  end

  defp current_activation_event_state(_repo, _actor_key, %ActorSessionActivation{}), do: :missing

  defp send_mailbox_updated(
         %{
           assignment: assignment,
           delivery: delivery,
           completed_at: completed_at,
           actor_event: input,
           turn_ref: turn_ref
         } = result
       ) do
    route = assignment.transport_route || assignment.worker_id
    envelope = TurnEnvelope.mailbox_updated(turn_ref, input)

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        with {:ok, completed_event} <- complete_active_steer_event(input.id, completed_at) do
          {:ok,
           result
           |> Map.put(:actor_event, completed_event)
           |> Map.put(:send_outcome, "sent_or_queued")}
        end

      {:error, reason} ->
        TurnLifecycle.mark_delivery_failed(delivery.id, reason, reason)
        WorkerAdmission.mark_route_unusable(route, reason)
        {:ok, Map.put(result, :send_outcome, Atom.to_string(reason))}
    end
  end

  defp complete_active_steer_event(actor_event_id, completed_at) do
    Repo.transact(fn repo ->
      case TurnLifecycle.lock_actor_event(repo, actor_event_id) do
        %ActorEvent{completed_at: %DateTime{}} = event ->
          {:ok, event}

        %ActorEvent{} = event ->
          with {:ok, _event} <-
                 Actors.complete_command_event_in_tx(repo, event,
                   completed_at: completed_at,
                   outbox_intents: []
                 ) do
            {:ok, %{event | completed_at: completed_at}}
          end

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
  end

  defp consume_command_feedback(repo, %ActorEvent{} = input, text, now) do
    with {:ok, outbox_intents} <- command_feedback_outbox_intents(repo, input, text),
         {:ok, completed_event} <-
           Actors.complete_command_event_in_tx(repo, input,
             completed_at: now,
             outbox_intents: outbox_intents
           ) do
      {:ok,
       %{
         status: :command_consumed,
         command: input.type,
         feedback: text,
         actor_event: completed_event
       }}
    end
  end

  defp consume_command_without_feedback(repo, %ActorEvent{} = input, now) do
    Actors.complete_command_event_in_tx(repo, input,
      completed_at: now,
      outbox_intents: []
    )
  end

  defp command_feedback_outbox_intents(_repo, %ActorEvent{signal_channel_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_outbox_intents(_repo, %ActorEvent{source_entry_id: nil}, _text),
    do: {:ok, []}

  defp command_feedback_outbox_intents(repo, %ActorEvent{} = input, text) do
    with {:ok, operation} <- SignalsGateway.outbox_operation_for_actor_event(input, repo) do
      command_name = String.replace_prefix(input.type, "command.", "")

      {:ok,
       [
         %{
           outbound_key: "command:#{input.id}:#{command_name}",
           operation: operation,
           target_source_entry_id: input.source_entry_id,
           provider_thread_id: input.provider_thread_id,
           payload: %{"text" => text},
           fallback_visible_text: text,
           idempotency_key: "command:#{input.id}:#{command_name}"
         }
       ]}
    end
  end

  defp append_retry_event(repo, actor_key, %ActorEvent{} = command_event, now) do
    with %Conversation{} = conversation <-
           TurnLifecycle.active_conversation_for_update(repo, actor_key),
         {:ok, retry_source} <- retry_source(repo, conversation) do
      Actors.append_actor_event_in_tx(repo, %{
        agent_uid: command_event.agent_uid,
        binding_name: command_event.binding_name,
        session_id: command_event.session_id,
        source_event_id: "retry:#{command_event.id}",
        signal_channel_id: command_event.signal_channel_id,
        provider_thread_id: command_event.provider_thread_id,
        source_entry_id: command_event.source_entry_id,
        type: "im.message.addressed",
        available_at: now,
        sender_key: command_event.sender_key,
        payload: %{
          "type" => "im.message.addressed",
          "data" => %{
            "entry" => %{
              "text" => retry_source.text,
              "retry_of_actor_event_id" => retry_source.actor_event_id,
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

  defp maybe_start_retry_preview({:ok, %{retry_actor_event: %ActorEvent{} = event}} = result) do
    _ = AIReplyPreview.maybe_start_for(event)
    result
  end

  defp maybe_start_retry_preview({:ok, %{retry_actor_events: events}} = result)
       when is_list(events) do
    Enum.each(events, fn
      %ActorEvent{} = event -> AIReplyPreview.maybe_start_for(event)
      _event -> :ok
    end)

    result
  end

  defp maybe_start_retry_preview(result), do: result

  defp publish_cancelled_turn_event({:ok, %{cancelled_turn: %Message{} = message}} = result) do
    error = message.metadata["error"] || %{"code" => "actor_runtime_cancel"}

    StatefulResponses.publish_terminal_event(message, :response_failed, %{
      error: error,
      response_id: "resp_#{message.id}",
      actor_event_id: message.metadata["actor_event_id"]
    })

    result
  end

  defp publish_cancelled_turn_event(result), do: result

  defp retry_source(repo, %Conversation{} = conversation) do
    Message
    |> where([message], message.conversation_id == ^conversation.id)
    |> where([message], message.type == "message")
    |> where([message], message.status in ["complete", "error"])
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(20)
    |> repo.all()
    |> Enum.find_value(&retry_source_from_message/1)
    |> case do
      %{text: text} = source when is_binary(text) and text != "" ->
        {:ok, source}

      _missing ->
        {:error, :retry_source_not_found}
    end
  end

  defp retry_source_from_message(%Message{metadata: metadata} = message) when is_map(metadata) do
    with actor_event_id when is_binary(actor_event_id) <- metadata["actor_event_id"],
         text when is_binary(text) and text != "" <- request_user_text(message.content) do
      %{
        actor_event_id: actor_event_id,
        message_id: message.id,
        text: text
      }
    else
      _missing -> nil
    end
  end

  defp retry_source_from_message(_message), do: nil

  defp request_user_text(content) when is_list(content) do
    content
    |> Enum.reverse()
    |> Enum.find_value(&request_user_item_text/1)
  end

  defp request_user_text(_content), do: nil

  defp request_user_item_text(%{"type" => "message", "role" => "user", "content" => content})
       when is_list(content),
       do: message_content_text(content)

  defp request_user_item_text(%{"type" => "message", "role" => "user", "content" => content})
       when is_binary(content),
       do: content

  defp request_user_item_text(%{"role" => "user", "content" => content}) when is_list(content),
    do: message_content_text(content)

  defp request_user_item_text(%{"role" => "user", "content" => content}) when is_binary(content),
    do: content

  defp request_user_item_text(_item), do: nil

  defp message_content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "input_text", "text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp cancel_live_turn(repo, actor_key, now, reason) do
    live_deliveries = live_deliveries_for_activation(repo, actor_key)

    case live_deliveries do
      [_delivery | _rest] ->
        actor_event_id = current_actor_event_id(live_deliveries)

        stop_controls =
          Enum.map(live_deliveries, &stop_control_for_delivery(actor_key, &1, reason))

        with {:ok, cancelled_turn} <-
               TurnLifecycle.cancel_started_turn_for_actor_event(
                 repo,
                 actor_event_id,
                 now,
                 reason
               ),
             {:ok, _completed_events} <-
               complete_cancelled_turn_events(repo, live_deliveries, now) do
          {:ok, %{stop_controls: stop_controls, cancelled_turn: cancelled_turn}}
        end

      [] ->
        {:ok, %{stop_controls: [], cancelled_turn: nil}}
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

  defp live_deliveries_for_activation(repo, actor_key) do
    case TurnLifecycle.live_activation(repo, actor_key) do
      %ActorSessionActivation{current_actor_event_id: actor_event_id}
      when is_binary(actor_event_id) ->
        ActorEventDelivery
        |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
        |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
        |> lock("FOR UPDATE")
        |> repo.all()

      _activation ->
        []
    end
  end

  defp complete_cancelled_turn_events(repo, deliveries, now) when is_list(deliveries) do
    deliveries
    |> Enum.uniq_by(& &1.actor_event_id)
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, completed_events} ->
      case TurnLifecycle.lock_actor_event(repo, delivery.actor_event_id) do
        %ActorEvent{} = event ->
          case Actors.mark_event_completed_in_tx(repo, event, now) do
            {:ok, completed_event} -> {:cont, {:ok, [completed_event | completed_events]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        nil ->
          {:cont, {:ok, completed_events}}
      end
    end)
  end

  defp stop_control_for_delivery(_actor_key, delivery, reason) do
    %{
      route: delivery.transport_route || delivery.worker_id,
      reason: reason,
      turn_ref: delivery |> TurnRef.from_delivery() |> TurnRef.to_wire()
    }
  end

  defp current_actor_event_id([
         %ActorEventDelivery{actor_event_id_fence: actor_event_id} | _rest
       ]),
       do: actor_event_id

  defp current_actor_event_id(_deliveries), do: nil

  defp end_active_conversation(repo, actor_key, now) do
    case TurnLifecycle.active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        live_deliveries = live_deliveries_for_activation(repo, actor_key)
        actor_event_id = current_actor_event_id(live_deliveries)

        stop_controls =
          Enum.map(live_deliveries, &stop_control_for_delivery(actor_key, &1, "command.new"))

        with {:ok, _conversation} <-
               conversation
               |> Conversation.changeset(%{ended_at: now})
               |> repo.update(),
             {:ok, cancelled_turn} <-
               TurnLifecycle.cancel_started_turn_for_actor_event(
                 repo,
                 actor_event_id,
                 now,
                 "command.new"
               ),
             {:ok, _completed_events} <-
               complete_cancelled_turn_events(repo, live_deliveries, now) do
          {:ok, %{stop_controls: stop_controls, cancelled_turn: cancelled_turn}}
        end

      nil ->
        {:ok, %{stop_controls: [], cancelled_turn: nil}}
    end
  end

  defp command_args(%ActorEvent{payload: payload}) when is_map(payload) do
    payload
    |> get_in(["data", "command", "argsText"])
    |> case do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp command_args(_input), do: ""
end
