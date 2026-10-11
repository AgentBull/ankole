defmodule Ankole.SignalsGateway.ActorRuntime.Common do
  @moduledoc false

  # RuntimeFabric `*_json` bytes fields carry UTF-8 JSON text; empty bytes mean
  # "absent". Producers are JSON serializers on both hosts, so invalid JSON is a
  # programming error and raises instead of degrading.
  def decode_json_bytes(bytes) when bytes in [nil, ""], do: nil
  def decode_json_bytes(bytes) when is_binary(bytes), do: Torque.decode!(bytes)

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
