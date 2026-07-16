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
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.Principals.Agent, as: PrincipalAgent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SystemConfig

  @spec handle_request(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id", trim: false) ||
        "agent-conversation-context-#{Ecto.UUID.generate()}"

    with {:ok, context} <- RuntimeContext.resolve(turn_ref),
         {:ok, brain_snapshot} <- Snapshot.get_or_create(context.conversation),
         {:ok, agent} <- agent_profile(turn_ref.agent_uid),
         {:ok, soul} <- Library.get_soul(turn_ref.agent_uid),
         {:ok, mission} <- Library.get_mission(turn_ref.agent_uid),
         {:ok, design} <- Library.get_design(turn_ref.agent_uid),
         {:ok, skills} <- Library.skills_for_system_prompt(turn_ref.agent_uid) do
      timezone = installation_timezone()
      system_prompt_snapshot = AIGatewayLink.system_prompt_snapshot(context.conversation)

      {:ok,
       %{
         "request_id" => request_id,
         "agent_uid" => turn_ref.agent_uid,
         "session_id" => turn_ref.session_id,
         "turn" => TurnRef.to_wire(turn_ref),
         "agent" => agent,
         "conversation" => conversation_payload(context.conversation, timezone),
         "soul" => soul,
         "mission" => mission,
         "design" => design,
         "skills" => skills,
         "brain_snapshot" => brain_snapshot
       }
       |> maybe_put("system_prompt_snapshot", system_prompt_snapshot)}
    else
      {:error, reason} -> error(request_id, reason)
    end
  end

  def handle_request(_turn_ref, _request, _route),
    do: error("", :invalid_agent_conversation_context_request)

  defp conversation_payload(conversation, timezone) do
    %{
      "id" => conversation.id,
      "key" => conversation.conversation_key,
      "started_at" => datetime(conversation.inserted_at),
      "timezone" => timezone
    }
  end

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

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error(request_id, reason) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "agent_conversation_context_request_failed",
       message_style: :tuple_inspect,
       details_json: %{}
     )}
  end
end
