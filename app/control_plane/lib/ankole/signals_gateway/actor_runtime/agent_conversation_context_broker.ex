defmodule Ankole.SignalsGateway.ActorRuntime.AgentConversationContextBroker do
  @moduledoc """
  Resolves PG-backed context for the current AI-agent conversation.

  This RPC intentionally does not return transcript messages or turn-local
  request context. Transcript history is owned by AIGateway; turn-local facts
  travel on `turn_start`.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Memory
  alias Ankole.Principals.Agent, as: PrincipalAgent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SystemConfig
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @spec handle_request(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id", trim: false) ||
        "agent-conversation-context-#{Ecto.UUID.generate()}"

    with {:ok, actor_event} <- actor_event(request),
         {:ok, context} <- conversation_context(turn_ref, actor_event),
         {:ok, agent} <- agent_profile(turn_ref.agent_uid),
         {:ok, soul} <- Library.get_soul(turn_ref.agent_uid),
         {:ok, mission} <- Library.get_mission(turn_ref.agent_uid),
         {:ok, skills} <- Library.skills_for_system_prompt(turn_ref.agent_uid) do
      timezone = installation_timezone()
      memory_notes = Memory.notes_for_context(turn_ref.agent_uid, context.channel_id)

      {:ok,
       %{
         "request_id" => request_id,
         "agent_uid" => turn_ref.agent_uid,
         "session_id" => turn_ref.session_id,
         "turn" => TurnRef.to_wire(turn_ref),
         "agent" => agent,
         "conversation" => conversation_payload(context, timezone),
         "soul" => soul,
         "mission" => mission,
         "skills" => skills,
         "memory_notes" => memory_notes,
         "cache_key" =>
           cache_key(context.cache_anchor, agent, soul, mission, skills, memory_notes, timezone)
       }}
    else
      {:error, reason} -> error(request_id, reason)
    end
  end

  def handle_request(_turn_ref, _request, _route),
    do: error("", :invalid_agent_conversation_context_request)

  defp active_conversation(%TurnRef{} = turn_ref) do
    AIGatewayLink.active_conversation(turn_ref.agent_uid, turn_ref.session_id)
  end

  defp conversation_context(%TurnRef{session_id: "subagent:" <> delegation_id} = turn_ref, _event) do
    case Repo.get_by(Delegation, id: delegation_id, agent_uid: turn_ref.agent_uid) do
      %Delegation{} = delegation ->
        {:ok,
         %{
           channel_id: Map.get(delegation.reply_route || %{}, "signal_channel_id"),
           conversation: nil,
           cache_anchor: {:subagent, delegation.id, delegation.session_id, delegation.reply_route}
         }}

      nil ->
        {:error, :delegation_not_found}
    end
  end

  defp conversation_context(%TurnRef{} = turn_ref, actor_event) do
    case active_conversation(turn_ref) do
      %{} = conversation ->
        {:ok,
         %{
           channel_id: current_channel_id(actor_event),
           conversation: conversation,
           cache_anchor:
             {:conversation, conversation.subject_uid, conversation.conversation_key,
              conversation.inserted_at}
         }}

      nil ->
        {:error, :conversation_not_found}
    end
  end

  defp conversation_payload(%{conversation: %{} = conversation}, timezone) do
    %{
      "id" => conversation.id,
      "key" => conversation.conversation_key,
      "started_at" => datetime(conversation.inserted_at),
      "timezone" => timezone
    }
  end

  defp conversation_payload(%{conversation: nil}, _timezone), do: %{}

  defp agent_profile(agent_uid) do
    case Repo.get(Principal, agent_uid) do
      %Principal{} = principal ->
        agent = Repo.get(PrincipalAgent, principal.uid)

        {:ok,
         %{
           "display_name" => principal.display_name || principal.uid,
           "role" => agent_role(agent)
         }}

      nil ->
        {:error, :agent_profile_not_found}
    end
  end

  defp agent_role(%PrincipalAgent{role: role}) when is_binary(role), do: role
  defp agent_role(_agent), do: ""

  defp installation_timezone do
    case SystemConfig.timezone() do
      {:ok, timezone} -> timezone
      {:error, _reason} -> SystemConfig.default_timezone()
    end
  end

  defp cache_key(anchor, agent, soul, mission, skills, memory_notes, timezone) do
    content =
      :erlang.term_to_binary({anchor, agent, soul, mission, skills, memory_notes, timezone})

    "agent-conversation-context:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  defp actor_event(%{"actor_event" => actor_event}) when is_map(actor_event),
    do: {:ok, RPCWire.stringify_keys(actor_event)}

  defp actor_event(%{actor_event: actor_event}) when is_map(actor_event),
    do: {:ok, RPCWire.stringify_keys(actor_event)}

  defp actor_event(_request), do: {:ok, %{}}

  defp current_channel_id(%{"signal_channel_id" => channel_id}) when is_binary(channel_id),
    do: channel_id

  defp current_channel_id(_actor_event), do: nil

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
