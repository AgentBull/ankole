defmodule Ankole.ActorRuntime.TurnContextBroker do
  @moduledoc """
  Resolves the PG-backed semantic context a worker needs for one turn.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Repo

  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "turn-context-#{Ecto.UUID.generate()}"

    with {:ok, turn} <- turn_ref(request),
         {agent_uid, session_id} <- actor_identity(turn),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :read),
         {:ok, soul} <- Library.get_soul(agent_uid),
         {:ok, mission} <- Library.get_mission(agent_uid),
         {:ok, skills} <- Library.skills_for_system_prompt(agent_uid) do
      {:ok,
       %{
         "request_id" => request_id,
         "agent_uid" => agent_uid,
         "session_id" => session_id,
         "turn" => turn,
         "soul" => soul,
         "mission" => mission,
         "skills" => skills,
         "conversation" => %{"messages" => conversation_messages(agent_uid, session_id)}
       }}
    else
      {:error, reason} ->
        {:error,
         %{
           "request_id" => request_id,
           "code" => error_code(reason),
           "message" => error_message(reason),
           "details_json" => %{}
         }}
    end
  end

  def handle_request(_request, _route),
    do:
      {:error,
       %{
         "request_id" => "",
         "code" => "invalid_turn_context_request",
         "message" => "invalid_turn_context_request",
         "details_json" => %{}
       }}

  defp conversation_messages(agent_uid, session_id) do
    Message
    |> join(:inner, [message], conversation in Conversation,
      on: conversation.id == message.conversation_id
    )
    |> where([message, conversation], conversation.agent_uid == ^String.downcase(agent_uid))
    |> where([message, conversation], conversation.conversation_key == ^session_id)
    |> where([_message, conversation], is_nil(conversation.ended_at))
    |> where([message, _conversation], message.status == "complete")
    |> order_by([message, _conversation], asc: message.inserted_at, asc: message.id)
    |> Repo.all()
    |> Enum.map(&message_payload/1)
  end

  defp message_payload(%Message{} = message) do
    %{
      "id" => message.id,
      "role" => message.role,
      "kind" => message.kind,
      "content" => message.content,
      "metadata" => message.metadata || %{},
      "inserted_at" => datetime(message.inserted_at)
    }
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

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "turn_context_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
