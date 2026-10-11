defmodule Ankole.SignalsGateway.ActorRuntime.TurnEnvelope do
  @moduledoc """
  Builds Worker envelopes for Codex Jobs and environment workspaces.

  The control plane owns durable execution state. This module converts domain
  payloads to the generated `Ankole.RuntimeFabric.V1.Envelope` structs and
  `*_json` bytes defined in `envelope.proto`.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Conversations.JobTurnRef
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire

  def turn_start(
        %JobTurnRef{} = turn_ref,
        %ActorEvent{} = actor_event,
        turn_start_spec,
        mode,
        context
      ) do
    message_id = "job-start-" <> Ecto.UUID.generate()

    %FabricProto.Envelope{
      message_id: message_id,
      body:
        {:turn_start,
         %FabricProto.TurnStart{
           mode: mode,
           agent_context: if(mode == "start" and not is_nil(context), do: agent_context(context)),
           turn: JobTurnRef.to_proto(turn_ref),
           actor_event: actor_event_envelope(actor_event),
           fetch_runtime_config: fetch_runtime_config(turn_ref.agent_uid),
           model_ref: turn_model_ref(turn_start_spec),
           request_context_json: Torque.encode!(turn_request_context(turn_start_spec)),
           hosted_tools: turn_hosted_tools(turn_start_spec),
           runtime_env: turn_runtime_env(turn_start_spec)
         }}
    }
  end

  @doc """
  Builds the mailbox-update envelope used for active steer commands.
  Active steer carries the single already-journaled actor event that caused this
  mailbox revision.
  """
  @spec mailbox_updated(JobTurnRef.t(), ActorEvent.t()) :: FabricProto.Envelope.t()
  def mailbox_updated(%JobTurnRef{} = turn_ref, %ActorEvent{} = actor_event) do
    message_id = "mailbox-updated-" <> Ecto.UUID.generate()

    %FabricProto.Envelope{
      message_id: message_id,
      body:
        {:mailbox_updated,
         %FabricProto.MailboxUpdated{
           turn: JobTurnRef.to_proto(turn_ref),
           actor_event: actor_event_envelope(actor_event)
         }}
    }
  end

  @doc """
  Builds a control envelope for an already-running turn.
  """
  @spec turn_control(JobTurnRef.t(), String.t(), map()) :: FabricProto.Envelope.t()
  def turn_control(turn_ref, command, payload \\ %{})

  def turn_control(%JobTurnRef{} = turn_ref, command, payload)
      when is_binary(command) and is_map(payload) do
    message_id = "turn-control-" <> Ecto.UUID.generate()

    %FabricProto.Envelope{
      message_id: message_id,
      body:
        {:turn_control,
         %FabricProto.TurnControl{
           turn: JobTurnRef.to_proto(turn_ref),
           command: command,
           payload_json: json_bytes_or_empty(payload)
         }}
    }
  end

  @doc "Encodes the authoritative context snapshot for Worker execution."
  def agent_context(context) do
    soul = Map.fetch!(context.documents, "soul")
    mission = Map.fetch!(context.documents, "mission")
    design = Map.fetch!(context.documents, "design")
    confidentiality_policy = Map.fetch!(context.documents, "confidentiality_policy")

    %FabricProto.AgentConversationContextResponse{
      skills_prompt: Map.get(context, :skills_prompt, ""),
      conversation: %FabricProto.ConversationInfo{
        timezone: context.conversation.timezone,
        drive_directory:
          case Map.get(context.conversation, :origin_channel) do
            %{id: channel_id} -> Ankole.Files.chat_directory(channel_id)
            _no_channel -> ""
          end
      },
      soul: soul["content"],
      mission: mission["content"],
      design: design["content"],
      confidentiality_policy: confidentiality_policy["content"],
      skills: Enum.map(context.skills, &RPCWire.runtime_skill_summary/1),
      agent_plugins: Enum.map(context.agent_plugins, &agent_plugin_catalog_entry/1)
    }
  end

  defp agent_plugin_catalog_entry(entry) do
    %FabricProto.AgentPluginCatalogEntry{
      id: entry["id"],
      skills:
        Enum.map(entry["skills"], fn skill ->
          %FabricProto.AgentPluginCatalogSkill{catalog_name: skill["catalog_name"]}
        end)
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
      provider_id: map_get(model_ref, :provider_id) || "",
      provider_kind: map_get(model_ref, :provider_kind) || "",
      model: map_get(model_ref, :model) || "",
      input_modalities: map_get(model_ref, :input_modalities) || [],
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

  defp fetch_runtime_config(agent_uid) do
    {:ok, config} =
      Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfig.runtime_config(agent_uid)

    config
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
      [_ | _] = tools ->
        normalized = Enum.map(tools, &normalize_turn_hosted_tool/1)

        if normalized != Enum.uniq(normalized) do
          raise ArgumentError, "duplicate turn hosted tools: #{inspect(tools)}"
        end

        normalized

      nil ->
        []

      tools ->
        raise ArgumentError, "invalid turn hosted tools: #{inspect(tools)}"
    end
  end

  defp normalize_turn_hosted_tool(%{} = tool) do
    case map_get(tool, :type) do
      "image_generation" -> :HOSTED_TOOL_IMAGE_GENERATION
      "web_search" -> :HOSTED_TOOL_WEB_SEARCH
      "brain" -> :HOSTED_TOOL_BRAIN
      type -> raise ArgumentError, "unsupported turn hosted tool: #{inspect(type)}"
    end
  end

  defp normalize_turn_hosted_tool(tool) do
    raise ArgumentError, "invalid turn hosted tool: #{inspect(tool)}"
  end

  defp map_get(map, key) when is_atom(key) and is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp actor_event_envelope(%ActorEvent{} = actor_event) do
    %FabricProto.ActorEventEnvelope{
      actor_event_id: actor_event.id,
      type: actor_event.type,
      binding_name: actor_event.binding_name || "",
      payload_json: json_bytes(actor_event.payload)
    }
  end

  defp json_bytes(nil), do: ""
  defp json_bytes(value), do: Torque.encode!(value)

  defp json_bytes_or_empty(payload) when payload == %{}, do: ""
  defp json_bytes_or_empty(payload), do: Torque.encode!(payload)
end
