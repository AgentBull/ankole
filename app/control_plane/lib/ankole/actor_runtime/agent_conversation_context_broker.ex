defmodule Ankole.ActorRuntime.AgentConversationContextBroker do
  @moduledoc """
  Resolves PG-backed context for the current AI-agent conversation.

  This RPC intentionally does not return transcript messages or turn-local
  request context. Workers fetch transcript history through
  `conversation.history.resolve`; turn-local facts travel on `turn_start`.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Principals.Agent, as: PrincipalAgent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SystemConfig

  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id =
      text(request, "request_id") || "agent-conversation-context-#{Ecto.UUID.generate()}"

    with {:ok, turn} <- turn_ref(request),
         {agent_uid, session_id} <- actor_identity(turn),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :read),
         %Conversation{} = conversation <- active_conversation(agent_uid, session_id),
         {:ok, agent} <- agent_profile(agent_uid),
         {:ok, soul} <- Library.get_soul(agent_uid),
         {:ok, mission} <- Library.get_mission(agent_uid),
         {:ok, skills} <- Library.skills_for_system_prompt(agent_uid) do
      timezone = installation_timezone()

      {:ok,
       %{
         "request_id" => request_id,
         "agent_uid" => conversation.agent_uid,
         "session_id" => conversation.conversation_key,
         "turn" => turn,
         "agent" => agent,
         "conversation" => %{
           "id" => conversation.id,
           "key" => conversation.conversation_key,
           "started_at" => datetime(conversation.inserted_at),
           "timezone" => timezone
         },
         "soul" => soul,
         "mission" => mission,
         "skills" => skills,
         "cache_key" => cache_key(conversation, agent, soul, mission, skills, timezone)
       }}
    else
      nil -> error(request_id, :conversation_not_found)
      {:error, reason} -> error(request_id, reason)
    end
  end

  def handle_request(_request, _route),
    do:
      {:error,
       %{
         "request_id" => "",
         "code" => "invalid_agent_conversation_context_request",
         "message" => "invalid_agent_conversation_context_request",
         "details_json" => %{}
       }}

  defp active_conversation(agent_uid, session_id) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^String.downcase(agent_uid))
    |> where([conversation], conversation.conversation_key == ^session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> Repo.one()
  end

  defp agent_profile(agent_uid) do
    case Repo.get(Principal, String.downcase(agent_uid)) do
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
      {:error, _reason} -> "Etc/UTC"
    end
  end

  defp cache_key(%Conversation{} = conversation, agent, soul, mission, skills, timezone) do
    content =
      :erlang.term_to_binary(
        {conversation.agent_uid, conversation.conversation_key, conversation.inserted_at, agent,
         soul, mission, skills, timezone}
      )

    "agent-conversation-context:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp actor_identity(%{"actor" => %{"agent_uid" => agent_uid, "session_id" => session_id}})
       when is_binary(agent_uid) and is_binary(session_id),
       do: {agent_uid, session_id}

  defp actor_identity(_turn), do: {"", ""}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil

  defp error(request_id, reason) do
    {:error,
     %{
       "request_id" => request_id,
       "code" => error_code(reason),
       "message" => error_message(reason),
       "details_json" => %{}
     }}
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "agent_conversation_context_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
