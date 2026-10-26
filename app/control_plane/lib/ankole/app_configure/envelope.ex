defmodule Ankole.AppConfigure.Envelope do
  @moduledoc "The stored plaintext or encrypted configuration envelope."
  use Ash.Type

  @plaintext "plaintext"
  @cipher "cipher"

  def plaintext(value), do: %{"type" => @plaintext, "value" => value}
  def cipher(value), do: %{"type" => @cipher, "value" => value}

  def parts(%{"type" => type, "value" => value}) when is_binary(type),
    do: parts(type, value)

  def parts(%{type: type, value: value}) when is_binary(type), do: parts(type, value)
  def parts(_envelope), do: {:error, :invalid_envelope}

  defp parts(@plaintext, value), do: {:ok, :plaintext, value}
  defp parts(@cipher, value), do: {:ok, :cipher, value}
  defp parts(type, _value), do: {:error, {:unknown_envelope_type, type}}

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints), do: cast(value)

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints), do: cast(value)

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: cast(value)

  defp cast(value) do
    case parts(value) do
      {:ok, _type, _value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end
end
