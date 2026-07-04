defmodule Ankole.ActorRuntime.AppConfigureBroker do
  @moduledoc """
  RuntimeFabric RPC broker for worker AppConfigure reads.

  Agent Computer is a trusted first-party runtime node, so it may read declared
  AppConfigure keys through the normal resolution semantics. The key list is
  supplied by worker code, not model input, and the returned values stay on the
  ephemeral RPC path.
  """

  alias Ankole.AppConfigure
  alias Ankole.Principals

  @doc """
  Handles `app_configure.resolve`.
  """
  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, _route) when is_map(request) do
    request_id = text(request, "request_id") || "app-configure-resolve-#{Ecto.UUID.generate()}"

    result =
      with {:ok, agent_uid} <- request_agent_uid(request),
           {:ok, keys} <- request_keys(request),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, values} <- resolve_keys(principal.uid, keys) do
        {:ok, response_payload(request_id, principal.uid, values)}
      end

    case result do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, error_payload(request_id, text(request, "agent_uid") || "", reason)}

      :disabled ->
        {:error, error_payload(request_id, text(request, "agent_uid") || "", :agent_disabled)}
    end
  end

  def handle_request(_request, _route),
    do: {:error, error_payload("", "", :invalid_app_configure_resolve_request)}

  defp request_agent_uid(request) do
    case text(request, "agent_uid") do
      nil -> {:error, :missing_agent_uid}
      agent_uid -> Principals.normalize_uid(agent_uid)
    end
  end

  defp request_keys(request) do
    case Map.get(request, "keys") || Map.get(request, :keys) do
      keys when is_list(keys) ->
        normalize_keys(keys)

      _value ->
        {:error, :invalid_app_configure_keys}
    end
  end

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
    %{
      "value" => resolution.value,
      "source" => Atom.to_string(resolution.source)
    }
    |> maybe_put("scope", resolution.scope)
  end

  defp response_payload(request_id, agent_uid, values) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "values" => values
    }
  end

  defp error_payload(request_id, agent_uid, reason) do
    %{
      "request_id" => request_id,
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => %{"agent_uid" => agent_uid}
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _key}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _key, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "app_configure_resolve_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end
end
