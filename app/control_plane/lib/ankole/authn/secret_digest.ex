defmodule Ankole.Authn.SecretDigest do
  @moduledoc false

  def digest(context, value) do
    {:ok, secret} = Ankole.SecretKeyBase.fetch()

    :crypto.mac(:hmac, :sha256, secret, [
      "ankole.authn:",
      context,
      ":",
      value
    ])
  end

  def matches?(expected, context, value) when is_binary(expected) and is_binary(value),
    do: Plug.Crypto.secure_compare(expected, digest(context, value))

  def matches?(_, _, _), do: false

  def code do
    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  def token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
