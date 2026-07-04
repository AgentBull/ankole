defmodule Ankole.ActorRuntime.SkillRegistryBroker do
  @moduledoc """
  Handles worker RPC requests for agent-installed skill observations.

  Installed skill files are worker filesystem facts. This broker only verifies
  the worker turn route and records the worker's authoritative observations in
  the control-plane registry.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.ActorRuntime.WorkerRouteAuth

  @spec handle_replace(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_replace(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "skills-installed-replace-#{Ecto.UUID.generate()}"

    with {:ok, turn} <- turn_ref(request),
         {agent_uid, session_id} <- actor_identity(turn),
         observations when is_list(observations) <- list_value(request, "observations"),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :read) do
      case Library.replace_installed_skill_observations(agent_uid, observations) do
        {:ok, result} ->
          {:ok,
           %{
             "request_id" => request_id,
             "agent_uid" => agent_uid,
             "session_id" => session_id,
             "changed" => result.changed,
             "skills" => result.skills,
             "files" => result.files,
             "content_hash" => result.content_hash
           }}

        {:error, reason} ->
          error(request_id, reason, %{"agent_uid" => agent_uid})
      end
    else
      nil -> error(request_id, :invalid_skill_observations, %{})
      {:error, reason} -> error(request_id, reason, %{})
    end
  end

  def handle_replace(_request, _route),
    do: error("", :invalid_skill_registry_request, %{})

  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp actor_identity(%{"actor" => %{"agent_uid" => agent_uid, "session_id" => session_id}})
       when is_binary(agent_uid) and is_binary(session_id),
       do: {String.downcase(agent_uid), session_id}

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
  defp error_code(_reason), do: "skill_registry_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp list_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_list(value) -> value
      _value -> nil
    end
  end
end
