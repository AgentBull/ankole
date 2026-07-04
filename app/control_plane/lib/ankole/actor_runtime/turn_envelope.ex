defmodule Ankole.ActorRuntime.TurnEnvelope do
  @moduledoc """
  Builds actor lane envelopes for worker turns.

  The runtime owns durable scheduling, lease, and delivery state. This module
  keeps the transport-facing envelope shape separate from those state machines.
  """

  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation

  @doc """
  Builds the compact fence that every worker reply must echo.
  """
  def turn_ref(actor_key, %ActorSessionActivation{} = activation) do
    %{
      "actor" => actor_ref(actor_key),
      "activation_uid" => activation.activation_uid,
      "actor_epoch" => activation.actor_epoch,
      # Source table: actor_session_activations.current_actor_event_id stores
      # actor_events.id for the currently running worker execution.
      "actor_event_id" => activation.current_actor_event_id,
      "revision" => activation.revision
    }
  end

  @doc """
  Builds the actor lane envelope sent to the computer worker.

  Each worker turn carries one actor event.
  """
  def turn_start(turn_ref, %ActorEvent{} = actor_event, deliveries, turn_start_spec)
      when is_map(turn_start_spec) do
    message_id =
      deliveries
      |> List.first()
      |> case do
        %ActorEventDelivery{actor_lane_message_id: message_id} -> message_id
        _delivery -> "turn-start-" <> Ecto.UUID.generate()
      end

    %{
      "protocol_version" => 1,
      "message_id" => message_id,
      "correlation_id" => message_id,
      "lane" => "LANE_TURN",
      "sent_at_unix_ms" => System.system_time(:millisecond),
      "durability" => "CONTROL_REPLAYABLE",
      "body" => %{
        "type" => "turn_start",
        "turn_start" => %{
          "turn" => turn_ref,
          "actor_event" => actor_event_envelope(actor_event),
          "model_ref" => turn_model_ref(turn_start_spec),
          "request_context" => turn_request_context(turn_start_spec)
        }
      }
    }
  end

  @doc """
  Builds the mailbox-update envelope used for active steer commands.
  Active steer carries the single already-journaled actor event that caused this
  mailbox revision.
  """
  def mailbox_updated(turn_ref, %ActorEvent{} = actor_event) do
    message_id = "mailbox-updated-" <> Ecto.UUID.generate()

    %{
      "protocol_version" => 1,
      "message_id" => message_id,
      "correlation_id" => message_id,
      "lane" => "LANE_TURN",
      "sent_at_unix_ms" => System.system_time(:millisecond),
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "mailbox_updated",
        "mailbox_updated" => %{
          "turn" => turn_ref,
          "reason" => "command.steer",
          "actor_event" => actor_event_envelope(actor_event)
        }
      }
    }
  end

  @doc """
  Builds a control envelope for an already-running turn.
  """
  def turn_control(turn_ref, command, payload \\ %{})
      when is_binary(command) and is_map(payload) do
    message_id = "turn-control-" <> Ecto.UUID.generate()

    %{
      "protocol_version" => 1,
      "message_id" => message_id,
      "correlation_id" => message_id,
      "lane" => "LANE_CONTROL",
      "sent_at_unix_ms" => System.system_time(:millisecond),
      "durability" => "CONTROL_DURABLE",
      "body" => %{
        "type" => "turn_control",
        "turn_control" => %{
          "turn" => turn_ref,
          "command" => command,
          "payload_json" => payload
        }
      }
    }
  end

  # ActorKey is a fence, not an agent profile. Display identity is resolved by
  # workers through RPCLane when a prompt actually needs it.
  defp actor_ref(actor_key) do
    %{
      "agent_uid" => actor_key.agent_uid,
      "session_id" => actor_key.session_id
    }
  end

  defp turn_model_ref(turn_start_spec) do
    model_ref = map_get(turn_start_spec, :model_ref) || %{}

    %{
      "profile" => map_get(model_ref, :profile),
      "provider_id" => map_get(model_ref, :provider_id),
      "provider_kind" => map_get(model_ref, :provider_kind),
      "model" => map_get(model_ref, :model),
      "input_modalities" => map_get(model_ref, :input_modalities)
    }
    |> maybe_put("vision_fallback_model_ref", map_get(model_ref, :vision_fallback_model_ref))
  end

  defp turn_request_context(turn_start_spec) do
    map_get(turn_start_spec, :request_context) || %{}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_get(map, key) when is_atom(key) and is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp actor_event_envelope(%ActorEvent{} = actor_event) do
    %{
      "actor_event_id" => actor_event.id,
      "queue_sequence" => actor_event.queue_sequence,
      "type" => actor_event.type,
      "source_event_id" => actor_event.source_event_id,
      "binding_name" => actor_event.binding_name,
      "signal_channel_id" => actor_event.signal_channel_id,
      "provider_thread_id" => actor_event.provider_thread_id,
      "source_entry_id" => actor_event.source_entry_id,
      "payload_json" => actor_event.payload
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
