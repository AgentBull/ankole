defmodule Ankole.SignalsGateway.ActorRuntime.TurnEnvelope do
  @moduledoc """
  Builds actor lane envelopes for worker turns.

  The runtime owns durable scheduling, lease, and delivery state. This module
  assembles the generated `Ankole.RuntimeFabric.V1.Envelope` structs so the
  envelope shape stays anchored to `envelope.proto`; domain payload maps become
  `*_json` bytes here and nowhere else.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @doc """
  Builds the compact fence that every worker reply must echo.
  """
  @spec turn_ref(map(), ActorSessionActivation.t()) :: TurnRef.t()
  def turn_ref(actor_key, %ActorSessionActivation{} = activation) do
    TurnRef.from_activation(actor_key, activation)
  end

  @doc """
  Builds the actor lane envelope sent to the computer worker.

  Each worker turn carries one actor event.
  """
  @spec turn_start(TurnRef.t(), ActorEvent.t(), [ActorEventDelivery.t()], map()) ::
          FabricProto.Envelope.t()
  def turn_start(%TurnRef{} = turn_ref, %ActorEvent{} = actor_event, deliveries, turn_start_spec)
      when is_map(turn_start_spec) do
    message_id =
      deliveries
      |> List.first()
      |> case do
        %ActorEventDelivery{actor_lane_message_id: message_id} -> message_id
        _delivery -> "turn-start-" <> Ecto.UUID.generate()
      end

    %FabricProto.Envelope{
      message_id: message_id,
      correlation_id: message_id,
      sent_at_unix_ms: System.system_time(:millisecond),
      body:
        {:turn_start,
         %FabricProto.TurnStart{
           turn: TurnRef.to_proto(turn_ref),
           actor_event: actor_event_envelope(actor_event),
           workspace_id: turn_workspace_id(turn_start_spec),
           model_ref: turn_model_ref(turn_start_spec),
           request_context_json: Torque.encode!(turn_request_context(turn_start_spec)),
           hosted_tools_json: json_bytes(turn_hosted_tools(turn_start_spec)),
           runtime_env: turn_runtime_env(turn_start_spec)
         }}
    }
  end

  @doc """
  Builds the mailbox-update envelope used for active steer commands.
  Active steer carries the single already-journaled actor event that caused this
  mailbox revision.
  """
  @spec mailbox_updated(TurnRef.t(), ActorEvent.t()) :: FabricProto.Envelope.t()
  def mailbox_updated(%TurnRef{} = turn_ref, %ActorEvent{} = actor_event) do
    message_id = "mailbox-updated-" <> Ecto.UUID.generate()

    %FabricProto.Envelope{
      message_id: message_id,
      correlation_id: message_id,
      sent_at_unix_ms: System.system_time(:millisecond),
      body:
        {:mailbox_updated,
         %FabricProto.MailboxUpdated{
           reason: "command.steer",
           turn: TurnRef.to_proto(turn_ref),
           actor_event: actor_event_envelope(actor_event)
         }}
    }
  end

  @doc """
  Builds a control envelope for an already-running turn.
  """
  @spec turn_control(TurnRef.t(), String.t(), map()) :: FabricProto.Envelope.t()
  def turn_control(turn_ref, command, payload \\ %{})

  def turn_control(%TurnRef{} = turn_ref, command, payload)
      when is_binary(command) and is_map(payload) do
    message_id = "turn-control-" <> Ecto.UUID.generate()

    %FabricProto.Envelope{
      message_id: message_id,
      correlation_id: message_id,
      sent_at_unix_ms: System.system_time(:millisecond),
      body:
        {:turn_control,
         %FabricProto.TurnControl{
           turn: TurnRef.to_proto(turn_ref),
           command: command,
           payload_json: json_bytes_or_empty(payload)
         }}
    }
  end

  defp turn_model_ref(turn_start_spec) do
    case map_get(turn_start_spec, :model_ref) do
      %{} = model_ref -> normalize_turn_model_ref(model_ref)
      _value -> nil
    end
  end

  defp normalize_turn_model_ref(model_ref) do
    %FabricProto.TurnModelRef{
      profile: map_get(model_ref, :profile) || "",
      provider_id: map_get(model_ref, :provider_id) || "",
      provider_kind: map_get(model_ref, :provider_kind) || "",
      model: map_get(model_ref, :model) || "",
      input_modalities: map_get(model_ref, :input_modalities) || [],
      max_completion_tokens: positive_integer(map_get(model_ref, :max_completion_tokens)),
      provider_options_json: json_bytes_or_empty(map_get(model_ref, :provider_options) || %{}),
      supports_parallel_tool_calls: map_get(model_ref, :supports_parallel_tool_calls) == true,
      context_length: positive_integer(map_get(model_ref, :context_length)),
      vision_fallback_model_ref:
        case map_get(model_ref, :vision_fallback_model_ref) do
          %{} = fallback -> normalize_turn_model_ref(fallback)
          _value -> nil
        end
    }
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp turn_workspace_id(turn_start_spec) do
    case map_get(turn_start_spec, :workspace_id) do
      workspace_id
      when is_integer(workspace_id) and workspace_id in 10_000..9_007_199_254_740_991 ->
        workspace_id

      workspace_id ->
        raise ArgumentError,
              "invalid turn session workspace id: #{inspect(workspace_id)}"
    end
  end

  defp turn_request_context(turn_start_spec) do
    map_get(turn_start_spec, :request_context) || %{}
  end

  defp turn_runtime_env(turn_start_spec) do
    case map_get(turn_start_spec, :runtime_env) do
      %{} = runtime_env ->
        Map.new(runtime_env, fn
          {name, value} when is_binary(name) and is_binary(value) -> {name, value}
          invalid -> raise ArgumentError, "invalid turn runtime env entry: #{inspect(invalid)}"
        end)

      nil ->
        %{}

      runtime_env ->
        raise ArgumentError, "invalid turn runtime env: #{inspect(runtime_env)}"
    end
  end

  defp turn_hosted_tools(turn_start_spec) do
    case map_get(turn_start_spec, :hosted_tools) do
      [%{} = tool] -> normalize_turn_hosted_tool(tool)
      nil -> nil
      tools -> raise ArgumentError, "invalid turn hosted tools: #{inspect(tools)}"
    end
  end

  defp normalize_turn_hosted_tool(tool) do
    case map_get(tool, :type) do
      "image_generation" -> [%{"type" => "image_generation"}]
      type -> raise ArgumentError, "unsupported turn hosted tool: #{inspect(type)}"
    end
  end

  defp map_get(map, key) when is_atom(key) and is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp actor_event_envelope(%ActorEvent{} = actor_event) do
    %FabricProto.ActorEventEnvelope{
      actor_event_id: actor_event.id,
      queue_sequence: actor_event.queue_sequence,
      type: actor_event.type,
      source_event_id: actor_event.source_event_id || "",
      source_entry_id: actor_event.source_entry_id || "",
      binding_name: actor_event.binding_name || "",
      signal_channel_id: actor_event.signal_channel_id || "",
      provider_thread_id: actor_event.provider_thread_id || "",
      payload_json: json_bytes(actor_event.payload)
    }
  end

  defp json_bytes(nil), do: ""
  defp json_bytes(value), do: Torque.encode!(value)

  defp json_bytes_or_empty(payload) when payload == %{}, do: ""
  defp json_bytes_or_empty(payload), do: Torque.encode!(payload)
end
