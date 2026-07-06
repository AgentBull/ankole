defmodule Ankole.ActorRuntime.SkillRegistryBroker do
  @moduledoc """
  Handles worker RPC requests for agent-installed skill observations.

  Installed skill files are worker filesystem facts. This broker only verifies
  the worker turn route and records the worker's authoritative observations in
  the control-plane registry.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.ActorRuntime.TurnRef

  @spec handle_replace(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_replace(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = text(request, "request_id") || "skills-installed-replace-#{Ecto.UUID.generate()}"

    with observations when is_list(observations) <- list_value(request, "observations") do
      case Library.replace_installed_skill_observations(turn_ref.agent_uid, observations) do
        {:ok, result} ->
          {:ok,
           %{
             "request_id" => request_id,
             "agent_uid" => turn_ref.agent_uid,
             "session_id" => turn_ref.session_id,
             "changed" => result.changed,
             "skills" => result.skills,
             "files" => result.files,
             "content_hash" => result.content_hash
           }}

        {:error, reason} ->
          error(request_id, reason, %{"agent_uid" => turn_ref.agent_uid})
      end
    else
      nil -> error(request_id, :invalid_skill_observations, %{})
    end
  end

  def handle_replace(_turn_ref, _request, _route),
    do: error("", :invalid_skill_registry_request, %{})

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
