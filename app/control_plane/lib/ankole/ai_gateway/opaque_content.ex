defmodule Ankole.AIGateway.OpaqueContent do
  @moduledoc """
  Reader-side decoding for AIGateway opaque values.

  AIGateway encodes marked tool parameters as versioned Base64URL values in
  the Worker-facing stream, so stored trajectories keep that form. The Rust
  API resolver decodes the values on the provider path. This module decodes
  them for readers of stored trajectory, such as the Console and the Job
  result message for the owner Agent. A value that does not decode stays
  verbatim, because a reader must not fail on one corrupt value.
  """

  @prefixes ["ankole-aigateway-opaque-v1:", "ankole-chat-encoded-v1:"]

  @doc "Decodes every AIGateway opaque value inside the given term."
  @spec reveal(term()) :: term()
  def reveal(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, reveal(child)} end)
  end

  def reveal(value) when is_list(value), do: Enum.map(value, &reveal/1)
  def reveal(value) when is_binary(value), do: reveal_string(value)
  def reveal(value), do: value

  # A whole opaque value starts with a prefix. Tool-call arguments are JSON
  # strings that hold opaque values one level down, so a string that only
  # contains a prefix goes through one JSON round trip. Anything else, for
  # example a shell command that quotes an opaque value, stays verbatim.
  defp reveal_string(value) do
    cond do
      starts_with_prefix?(value) -> decode_or_keep(value)
      contains_prefix?(value) -> reveal_embedded_json(value)
      true -> value
    end
  end

  defp reveal_embedded_json(value) do
    with {:ok, %{} = fields} <- Ankole.JSON.decode(value),
         revealed = Map.new(fields, fn {key, field} -> {key, reveal_direct(field)} end),
         true <- revealed != fields do
      Ankole.JSON.encode!(revealed)
    else
      _other -> value
    end
  end

  defp reveal_direct(field) when is_binary(field) do
    if starts_with_prefix?(field), do: decode_or_keep(field), else: field
  end

  defp reveal_direct(field), do: field

  defp decode_or_keep(value) do
    prefix = Enum.find(@prefixes, &String.starts_with?(value, &1))
    payload = String.replace_prefix(value, prefix, "")

    case Base.url_decode64(payload, padding: false) do
      {:ok, decoded} -> if String.valid?(decoded), do: decoded, else: value
      :error -> value
    end
  end

  defp starts_with_prefix?(value), do: Enum.any?(@prefixes, &String.starts_with?(value, &1))
  defp contains_prefix?(value), do: Enum.any?(@prefixes, &String.contains?(value, &1))
end
