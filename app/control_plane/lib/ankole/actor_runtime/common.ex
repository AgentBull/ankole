defmodule Ankole.ActorRuntime.Common do
  @moduledoc false

  def unwrap_body(%{"body" => %{"type" => type} = body}, type), do: fetch_map!(body, type)
  def unwrap_body(%{body: %{"type" => type} = body}, type), do: fetch_map!(body, type)
  def unwrap_body(%{body: %{type: type} = body}, type), do: fetch_map!(body, type)

  def unwrap_body(%{} = map, type),
    do: fetch_map(map, type) || fetch_map(map, String.to_atom(type)) || map

  def normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  def normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  def normalize_uid(value) when is_binary(value), do: String.downcase(value)

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_value), do: false

  def fetch_actor_agent_uid(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("agent_uid") |> normalize_uid()

  def fetch_actor_session_id(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("session_id")

  def fetch_turn_id(turn_ref), do: fetch_text!(turn_ref, "llm_turn_id")

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

  def collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
