defmodule Ankole.ActorRuntime.SkillOverlayBroker do
  @moduledoc """
  Handles worker RPC requests for DB-backed skill overlays.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.ActorRuntime.WorkerRouteAuth

  @spec handle_request(String.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(action, request, route)
      when action in ["resolve", "replace", "clear"] and is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "skill-overlay-#{Ecto.UUID.generate()}"

    with {:ok, turn} <- turn_ref(request),
         {agent_uid, session_id} <- actor_identity(turn),
         skill_name when is_binary(skill_name) <- text(request, "skill_name"),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, effect_for(action)) do
      dispatch_action(action, request_id, agent_uid, session_id, skill_name, request)
    else
      nil -> error(request_id, :missing_skill_name, %{})
      {:error, reason} -> error(request_id, reason, %{})
    end
  end

  def handle_request(_action, _request, _route),
    do: error("", :invalid_skill_overlay_request, %{})

  defp dispatch_action("resolve", request_id, agent_uid, session_id, skill_name, _request) do
    case Library.skill_overlay(agent_uid, skill_name) do
      {:ok, overlay} -> {:ok, response(request_id, agent_uid, session_id, skill_name, overlay)}
      {:error, reason} -> error(request_id, reason, %{"skill_name" => skill_name})
    end
  end

  defp dispatch_action("replace", request_id, agent_uid, session_id, skill_name, request) do
    overlay_json =
      case map_value(request, "overlay_json") do
        %{} = overlay -> overlay
        _value -> %{"text" => text(request, "content") || ""}
      end

    case Library.replace_skill_overlay(agent_uid, skill_name, overlay_json) do
      {:ok, overlay} -> {:ok, response(request_id, agent_uid, session_id, skill_name, overlay)}
      {:error, reason} -> error(request_id, reason, %{"skill_name" => skill_name})
    end
  end

  defp dispatch_action("clear", request_id, agent_uid, session_id, skill_name, _request) do
    case Library.clear_skill_overlay(agent_uid, skill_name) do
      {:ok, overlay} -> {:ok, response(request_id, agent_uid, session_id, skill_name, overlay)}
      {:error, reason} -> error(request_id, reason, %{"skill_name" => skill_name})
    end
  end

  defp response(request_id, agent_uid, session_id, skill_name, %AgentSkillOverlay{} = overlay) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "session_id" => session_id,
      "skill_name" => skill_name,
      "has_overlay" => is_nil(overlay.deleted_at),
      "overlay_json" =>
        if(is_nil(overlay.deleted_at), do: overlay.overlay_json || %{}, else: %{}),
      "content_hash" => overlay.content_hash || ""
    }
  end

  defp response(request_id, agent_uid, session_id, skill_name, _overlay) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "session_id" => session_id,
      "skill_name" => skill_name,
      "has_overlay" => false,
      "overlay_json" => %{},
      "content_hash" => ""
    }
  end

  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp effect_for("resolve"), do: :read
  defp effect_for("replace"), do: :write
  defp effect_for("clear"), do: :write

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

  defp error(request_id, reason, details) do
    {:error,
     %{
       "request_id" => request_id,
       "code" => error_code(reason),
       "message" => error_message(reason),
       "details_json" => details
     }}
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "skill_overlay_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp map_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_map(value) -> value
      _value -> nil
    end
  end
end
