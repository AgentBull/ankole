defmodule Ankole.SignalsGateway.ToolOutput do
  @moduledoc false

  alias Ankole.JSON

  def decode(output) when is_binary(output) do
    output
    |> String.trim()
    |> decode_json_or_wrapped()
  end

  def decode(output) when is_map(output), do: output
  def decode(_output), do: nil

  defp decode_json_or_wrapped(output) do
    case JSON.decode(output) do
      {:ok, decoded} ->
        decoded

      {:error, _reason} ->
        case unwrap_untrusted(output) do
          {:ok, unwrapped} -> unwrapped |> String.trim() |> decode_json_or_wrapped()
          :error -> nil
        end
    end
  end

  defp unwrap_untrusted(output) do
    prefix = ~s(<ankole_untrusted_tool_output nonce=")

    with true <- String.starts_with?(output, prefix),
         rest <- String.replace_prefix(output, prefix, ""),
         [nonce, body_with_suffix] <- String.split(rest, ~s(">\n), parts: 2),
         suffix <- ~s(\n</ankole_untrusted_tool_output nonce="#{nonce}">),
         true <- String.ends_with?(body_with_suffix, suffix) do
      {:ok, String.replace_suffix(body_with_suffix, suffix, "")}
    else
      _not_wrapped -> :error
    end
  end
end
