defmodule Ankole.Plugins.WhatsAppAdapter.Signature do
  @moduledoc false

  @doc """
  Checks the `x-hub-signature-256` header: `sha256=` and the lowercase hex
  HMAC-SHA256 of the exact request bytes, keyed with the App secret.
  """
  @spec valid?(binary(), String.t() | nil, String.t()) :: boolean()
  def valid?(raw_body, header, app_secret)
      when is_binary(raw_body) and is_binary(header) and is_binary(app_secret) do
    Plug.Crypto.secure_compare(sign(raw_body, app_secret), header)
  end

  def valid?(_raw_body, _header, _app_secret), do: false

  @spec sign(binary(), String.t()) :: String.t()
  def sign(raw_body, app_secret) when is_binary(raw_body) and is_binary(app_secret) do
    digest = :hmac |> :crypto.mac(:sha256, app_secret, raw_body) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end
end
