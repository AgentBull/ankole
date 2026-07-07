defmodule Ankole.ActorRuntime.SkillRegistryBroker do
  @moduledoc """
  Handles worker RPC requests for agent-installed skill observations.

  Installed skill files are worker filesystem facts. This broker only verifies
  the worker turn route and records the worker's authoritative observations in
  the control-plane registry.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.ActorRuntime.RPCWire
  alias Ankole.ActorRuntime.TurnRef

  @spec handle_replace(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_replace(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id", trim: false) ||
        "skills-installed-replace-#{Ecto.UUID.generate()}"

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
     RPCWire.error_payload(request_id, reason,
       fallback_code: "skill_registry_request_failed",
       message_style: :tuple_inspect,
       details_json: details
     )}
  end

  defp list_value(map, key) do
    case RPCWire.value(map, key) do
      value when is_list(value) -> value
      _value -> nil
    end
  end
end
