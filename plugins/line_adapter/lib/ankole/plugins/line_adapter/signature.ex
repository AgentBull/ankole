defmodule Ankole.Plugins.LineAdapter.Signature do
  @moduledoc false

  @doc """
  Checks the `x-line-signature` header: the Base64 HMAC-SHA256 of the exact
  request bytes keyed with the channel secret.
  """
  @spec valid?(binary(), String.t() | nil, String.t()) :: boolean()
  def valid?(raw_body, header, channel_secret)
      when is_binary(raw_body) and is_binary(header) and is_binary(channel_secret) do
    expected = :hmac |> :crypto.mac(:sha256, channel_secret, raw_body) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, header)
  end

  def valid?(_raw_body, _header, _channel_secret), do: false

  @spec sign(binary(), String.t()) :: String.t()
  def sign(raw_body, channel_secret) when is_binary(raw_body) and is_binary(channel_secret) do
    :hmac |> :crypto.mac(:sha256, channel_secret, raw_body) |> Base.encode64()
  end
end
