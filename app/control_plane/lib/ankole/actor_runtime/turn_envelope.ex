defmodule Ankole.ActorRuntime.TurnEnvelope do
  @moduledoc """
  Builds actor lane envelopes for worker turns.

  The runtime owns durable scheduling, lease, and delivery state. This module
  keeps the transport-facing envelope shape separate from those state machines.
  """

  alias Ankole.Actors.ActorInput
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation

  @doc """
  Builds the compact fence that every worker reply must echo.
  """
  def turn_ref(_repo, actor_key, %ActorSessionActivation{} = activation, %LlmTurn{} = llm_turn) do
    %{
      "actor" => actor_ref(actor_key),
      "activation_uid" => activation.activation_uid,
      "actor_epoch" => activation.actor_epoch,
      "llm_turn_id" => llm_turn.id,
      "revision" => activation.revision
    }
  end

  @doc """
  Builds the actor lane envelope sent to the computer worker.
  """
  def turn_start(turn_ref, actor_inputs, deliveries, %LlmTurn{} = llm_turn) do
    message_id =
      deliveries
      |> List.first()
      |> case do
        %ActorInputDelivery{actor_lane_message_id: message_id} -> message_id
        _delivery -> "turn-start-" <> Ecto.UUID.generate()
      end

    %{
      "protocol_version" => 1,
      "message_id" => message_id,
      "correlation_id" => message_id,
      "seq" => 0,
      "lane" => "LANE_TURN",
      "sent_at_unix_ms" => System.system_time(:millisecond),
      "durability" => "CONTROL_REPLAYABLE",
      "body" => %{
        "type" => "turn_start",
        "turn_start" => %{
          "turn" => turn_ref,
          "inputs" => Enum.map(actor_inputs, &actor_input_envelope(&1, llm_turn)),
          "model_ref" => turn_model_ref(llm_turn)
        }
      }
    }
  end

  @doc """
  Builds the mailbox-update envelope used for active steer commands.
  """
  def mailbox_updated(turn_ref, actor_inputs) when is_list(actor_inputs) do
    message_id = "mailbox-updated-" <> Ecto.UUID.generate()

    %{
      "protocol_version" => 1,
      "message_id" => message_id,
      "correlation_id" => message_id,
      "seq" => 0,
      "lane" => "LANE_TURN",
      "sent_at_unix_ms" => System.system_time(:millisecond),
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "mailbox_updated",
        "mailbox_updated" => %{
          "turn" => turn_ref,
          "inputs" => Enum.map(actor_inputs, &actor_input_envelope/1),
          "actor" => turn_ref["actor"],
          "activation_uid" => turn_ref["activation_uid"],
          "actor_epoch" => turn_ref["actor_epoch"],
          "reason" => "command.steer"
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
      "seq" => 0,
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

  defp turn_model_ref(%LlmTurn{} = llm_turn) do
    %{
      "profile" => llm_turn.profile,
      "provider_id" =>
        get_in(llm_turn.provider_metadata || %{}, ["provider_id"]) || llm_turn.provider,
      "model" => llm_turn.model
    }
  end

  defp actor_input_envelope(%ActorInput{} = actor_input, %LlmTurn{kind: "compression"} = llm_turn) do
    actor_input
    |> actor_input_envelope()
    |> Map.put("payload_json", compression_actor_input_payload(actor_input, llm_turn))
  end

  defp actor_input_envelope(%ActorInput{} = actor_input, %LlmTurn{}),
    do: actor_input_envelope(actor_input)

  defp actor_input_envelope(%ActorInput{} = actor_input) do
    %{
      "actor_input_id" => actor_input.id,
      "broker_sequence" => actor_input.broker_sequence,
      "type" => actor_input.type,
      "ingress_event_id" => actor_input.ingress_event_id,
      "provider_entry_id" => actor_input.provider_entry_id,
      "payload_json" => actor_input.payload
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compression_actor_input_payload(%ActorInput{} = actor_input, %LlmTurn{} = llm_turn) do
    compression = get_in(llm_turn.request_context || %{}, ["compression"]) || %{}

    %{
      "type" => actor_input.type,
      "data" => %{
        "command" => %{
          "name" => "compress",
          "argsText" => ""
        },
        "compression" => compression
      }
    }
  end
end
