defmodule Ankole.SignalsGateway.ActorRuntime.AppConfigureBroker do
  @moduledoc """
  RuntimeFabric RPC broker for worker AppConfigure reads.

  Agent Computer is a trusted first-party runtime node, so it may read declared
  AppConfigure keys through the normal resolution semantics. The key list is
  supplied by worker code, not model input, and the returned values stay on the
  ephemeral RPC path.
  """

  alias Ankole.AppConfigure
  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire

  @doc """
  Handles `app_configure.resolve`.
  """
  @spec handle_request(String.t() | nil, FabricProto.AppConfigureResolveRequest.t(), map()) ::
          {:ok, FabricProto.AppConfigureResolveResponse.t()} | {:error, map()}
  def handle_request(agent_uid, %FabricProto.AppConfigureResolveRequest{} = request, ctx) do
    result =
      with {:ok, agent_uid} <- frame_agent_uid(agent_uid),
           {:ok, keys} <- normalize_keys(request.keys),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, values} <- resolve_keys(principal.uid, keys) do
        {:ok, %FabricProto.AppConfigureResolveResponse{values: values}}
      end

    case result do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, error_payload(ctx.request_id, agent_uid, reason)}
      :disabled -> {:error, error_payload(ctx.request_id, agent_uid, :agent_disabled)}
    end
  end

  defp frame_agent_uid(nil), do: {:error, :missing_agent_uid}
  defp frame_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp normalize_keys(keys) do
    keys
    |> Enum.reduce_while({:ok, []}, fn
      key, {:ok, acc} when is_binary(key) ->
        case String.trim(key) do
          "" -> {:halt, {:error, :invalid_app_configure_key}}
          key -> {:cont, {:ok, [key | acc]}}
        end

      _key, _acc ->
        {:halt, {:error, :invalid_app_configure_key}}
    end)
    |> case do
      {:ok, []} -> {:error, :empty_app_configure_keys}
      {:ok, keys} -> {:ok, keys |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_keys(agent_uid, keys) do
    keys
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      case AppConfigure.resolve_by_key(key, agent_id: agent_uid) do
        {:ok, resolution} ->
          {:cont, {:ok, Map.put(acc, key, resolution_payload(resolution))}}

        :error ->
          {:halt, {:error, {:app_configure_key_not_resolved, key}}}

        {:error, reason} ->
          {:halt, {:error, {:app_configure_resolve_failed, key, reason}}}
      end
    end)
  end

  defp resolution_payload(resolution) do
    %FabricProto.AppConfigureResolution{
      value_json: Torque.encode!(resolution.value),
      source: Atom.to_string(resolution.source)
    }
  end

  defp error_payload(request_id, agent_uid, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "app_configure_resolve_failed",
      message_style: :tuple_inspect,
      details_json: %{"agent_uid" => agent_uid || ""}
    )
  end
end
