defmodule Ankole.Observability.UserID do
  @moduledoc false

  @max_codepoints 200
  @no_user "none"
  @prefixes ["principal:", "channel:"]

  @spec principal(String.t()) :: String.t() | nil
  def principal(value), do: prefixed("principal:", value)

  @spec channel(String.t()) :: String.t() | nil
  def channel(value), do: prefixed("channel:", value)

  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(value) when is_binary(value) do
    if String.valid?(value) and value == String.trim(value) and
         not String.contains?(value, ["\r", "\n"]) and
         codepoint_length(value) <= @max_codepoints and valid_prefix?(value) do
      {:ok, value}
    else
      :error
    end
  end

  def normalize(_value), do: :error

  @spec decode_carrier(term()) :: {:ok, String.t() | nil} | :error
  def decode_carrier(@no_user), do: {:ok, nil}

  def decode_carrier(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, user_id} <- normalize(decoded) do
      {:ok, user_id}
    else
      _invalid -> :error
    end
  end

  def decode_carrier(_value), do: :error

  defp prefixed(prefix, value) when is_binary(value), do: normalize_value(prefix <> value)
  defp prefixed(_prefix, _value), do: nil

  defp normalize_value(value) do
    case normalize(value) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp valid_prefix?(value) do
    Enum.any?(@prefixes, fn prefix ->
      String.starts_with?(value, prefix) and value != prefix
    end)
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()
end
