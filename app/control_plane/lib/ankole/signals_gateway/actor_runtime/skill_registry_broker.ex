defmodule Ankole.SignalsGateway.ActorRuntime.SkillRegistryBroker do
  @moduledoc """
  Handles worker RPC requests for agent-installed skill observations.

  Installed skill files are worker filesystem facts. This broker only verifies
  the worker turn route and records the worker's authoritative observations in
  the control-plane registry.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_replace(TurnRef.t(), FabricProto.InstalledSkillReplaceRequest.t(), map()) ::
          {:ok, FabricProto.InstalledSkillReplaceResponse.t()} | {:error, map()}
  def handle_replace(
        %TurnRef{} = turn_ref,
        %FabricProto.InstalledSkillReplaceRequest{} = request,
        ctx
      ) do
    observations = Enum.map(request.observations, &observation_attrs/1)

    case Library.replace_installed_skill_observations(turn_ref.agent_uid, observations) do
      {:ok, _result} ->
        {:ok, %FabricProto.InstalledSkillReplaceResponse{}}

      {:error, reason} ->
        error(ctx.request_id, reason, %{"agent_uid" => turn_ref.agent_uid})
    end
  end

  # The Library observation contract is a string-keyed map where absent keys
  # take defaults; empty proto strings mean absent.
  defp observation_attrs(%FabricProto.InstalledSkillObservation{} = observation) do
    %{
      "skill_name" => observation.skill_name,
      "tags" => observation.tags,
      "disable_model_invocation" => observation.disable_model_invocation
    }
    |> put_present("description", observation.description)
    |> put_present("category", observation.category)
    |> put_present("ankole_runtime", observation.ankole_runtime)
    |> put_optional("default_enabled", observation.default_enabled)
  end

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_present(map, _key, _value), do: map

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp error(request_id, reason, details) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "skill_registry_request_failed",
       message_style: :tuple_inspect,
       details_json: details
     )}
  end
end
