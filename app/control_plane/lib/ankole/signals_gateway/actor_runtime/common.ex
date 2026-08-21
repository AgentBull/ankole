defmodule Ankole.SignalsGateway.ActorRuntime.Common do
  @moduledoc false

  # RuntimeFabric `*_json` bytes fields carry UTF-8 JSON text; empty bytes mean
  # "absent". Producers are JSON serializers on both hosts, so invalid JSON is a
  # programming error and raises instead of degrading.
  def decode_json_bytes(bytes) when bytes in [nil, ""], do: nil
  def decode_json_bytes(bytes) when is_binary(bytes), do: Torque.decode!(bytes)

  def normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: Ankole.PrincipalKey.canonicalize(agent_uid), session_id: session_id}
  end

  def normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: Ankole.PrincipalKey.canonicalize(agent_uid), session_id: session_id}
  end

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_value), do: false

  def fetch_text!(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  def fetch_text(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  def fetch_map!(map, key) do
    case fetch_map(map, key) do
      %{} = value -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  def fetch_map(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)

  def fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  def map_text(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  def map_text(_map, _key), do: nil

  def map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  def map_value(_map, _key), do: nil

  def fetch_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  def fetch_int!(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  def reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def normalize_outcome(value) when is_atom(value), do: Atom.to_string(value)
  def normalize_outcome(value), do: value

  def reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(reason), do: inspect(reason)

  defdelegate collect_results(results), to: Ankole.Attrs
end
