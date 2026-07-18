defmodule Ankole.SignalsGateway.ActorRuntime.SkillRegistryBroker do
  @moduledoc """
  Handles worker RPC requests for agent-installed skill observations.

  Installed skill files are worker filesystem facts. This broker only verifies
  the worker turn route and records the worker's authoritative observations in
  the control-plane registry.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Common
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
      {:ok, result} ->
        {:ok,
         %FabricProto.InstalledSkillReplaceResponse{
           changed: result.changed,
           skills: result.skills,
           files: result.files,
           content_hash: result.content_hash
         }}

      {:error, reason} ->
        error(ctx.request_id, reason, %{"agent_uid" => turn_ref.agent_uid})
    end
  end

  # The Library observation contract is a string-keyed map where absent keys
  # take defaults; empty proto strings mean absent.
  defp observation_attrs(%FabricProto.InstalledSkillObservation{} = observation) do
    %{"skill_name" => observation.skill_name}
    |> put_present("relative_path", observation.relative_path)
    |> put_present("description", observation.description)
    |> put_present("content_hash", observation.content_hash)
    |> put_present("xxh3_128", observation.xxh3_128)
    |> put_optional("default_enabled", observation.default_enabled)
    |> put_optional("file_count", observation.file_count)
    |> put_metadata(observation.metadata_json)
  end

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_present(map, _key, _value), do: map

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp put_metadata(map, metadata_json) do
    case Common.decode_json_bytes(metadata_json) do
      %{} = metadata -> Map.put(map, "metadata", metadata)
      _value -> map
    end
  end

  defp error(request_id, reason, details) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "skill_registry_request_failed",
       message_style: :tuple_inspect,
       details_json: details
     )}
  end
end
