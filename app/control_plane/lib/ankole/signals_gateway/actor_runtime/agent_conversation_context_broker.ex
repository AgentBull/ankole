defmodule Ankole.SignalsGateway.ActorRuntime.AgentConversationContextBroker do
  @moduledoc """
  Resolves PG-backed context for the current AI-agent conversation.

  This RPC intentionally does not return transcript messages or turn-local
  request context. Transcript history is owned by AIGateway; turn-local facts
  travel on `turn_start`.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.Brain.RuntimeContext
  alias Ankole.Brain.Snapshot
  alias Ankole.Principals.Agent, as: PrincipalAgent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ConversationChannel, as: ConversationChannelProjection
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SystemConfig

  @spec handle_request(TurnRef.t(), FabricProto.AgentConversationContextRequest.t(), map()) ::
          {:ok, FabricProto.AgentConversationContextResponse.t()} | {:error, map()}
  def handle_request(%TurnRef{} = turn_ref, %FabricProto.AgentConversationContextRequest{}, ctx) do
    with {:ok, context} <- RuntimeContext.resolve(turn_ref),
         {:ok, brain_snapshot} <- Snapshot.get_or_create(context.conversation),
         {:ok, agent} <- agent_profile(turn_ref.agent_uid),
         {:ok, documents} <- Library.list_agent_documents(turn_ref.agent_uid),
         {:ok, skills} <- Library.skills_for_system_prompt(turn_ref.agent_uid) do
      timezone = installation_timezone()
      soul = Map.fetch!(documents, "soul")
      mission = Map.fetch!(documents, "mission")
      design = Map.fetch!(documents, "design")

      {:ok,
       %FabricProto.AgentConversationContextResponse{
         agent: agent,
         conversation: conversation_info(context.conversation, timezone),
         soul: soul["content"],
         mission: mission["content"],
         design: design["content"],
         soul_content_hash: soul["content_hash"],
         mission_content_hash: mission["content_hash"],
         design_content_hash: design["content_hash"],
         brain_snapshot: brain_snapshot_message(brain_snapshot),
         skills: Enum.map(skills, &RPCWire.runtime_skill_summary/1)
       }}
    else
      {:error, reason} -> error(ctx.request_id, reason)
    end
  end

  defp conversation_info(conversation, timezone) do
    %FabricProto.ConversationInfo{
      id: conversation.id,
      key: conversation.conversation_key,
      started_at: datetime(conversation.inserted_at) || "",
      timezone: timezone,
      origin_channel: conversation |> ConversationChannelProjection.origin() |> origin_channel()
    }
  end

  defp origin_channel(%{} = channel) do
    %FabricProto.ConversationChannel{
      adapter: channel.adapter || "",
      kind: channel.kind || "",
      label: channel.label || ""
    }
  end

  defp origin_channel(_channel), do: nil

  defp agent_profile(agent_uid) do
    case Repo.get(Principal, agent_uid) do
      %Principal{} = principal ->
        agent = Repo.get(PrincipalAgent, principal.uid)

        {:ok,
         %FabricProto.AgentProfile{
           display_name: principal.display_name || principal.uid,
           role: agent_role(agent)
         }}

      nil ->
        {:error, :agent_profile_not_found}
    end
  end

  defp agent_role(%PrincipalAgent{role: role}) when is_binary(role), do: role
  defp agent_role(_agent), do: ""

  defp brain_snapshot_message(snapshot) when is_map(snapshot) do
    %FabricProto.BrainSnapshot{
      pinned_memo: snapshot_entry(RPCWire.map_value(snapshot, "pinned_memo")),
      channel_entry: snapshot_entry(RPCWire.map_value(snapshot, "channel_entry"))
    }
  end

  defp brain_snapshot_message(_snapshot), do: nil

  defp snapshot_entry(%{} = entry) do
    %FabricProto.BrainSnapshotEntry{
      resident_text: RPCWire.text(entry, "resident_text", trim: false) || "",
      truncated: RPCWire.value(entry, "truncated") == true
    }
  end

  defp snapshot_entry(_entry), do: nil

  defp installation_timezone do
    case SystemConfig.timezone() do
      {:ok, timezone} -> timezone
      {:error, _reason} -> SystemConfig.default_timezone()
    end
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil

  defp error(request_id, reason) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "agent_conversation_context_request_failed",
       message_style: :tuple_inspect,
       details_json: %{}
     )}
  end
end
