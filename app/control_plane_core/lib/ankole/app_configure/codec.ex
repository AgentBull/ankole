defmodule Ankole.AppConfigure.Codec do
  @moduledoc """
  Converts AppConfigure runtime values to and from database envelopes.
  """

  alias Ankole.AppConfigure.Crypto
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition

  @plaintext "plaintext"
  @cipher "cipher"

  @type definition :: Definition.t() | PatternDefinition.t()

  @doc """
  Validates a runtime value and converts it into a database envelope.

  Validation runs before encryption so encrypted rows store only schema-approved
  JSON values, not arbitrary Elixir terms.
  """
  @spec dump(definition(), String.t(), String.t(), term()) ::
          {:ok, map(), term()} | {:error, term()}
  def dump(definition, scope, key, value) do
    with {:ok, parsed} <- validate(definition, value),
         {:ok, envelope} <- encode_envelope(definition, scope, key, parsed) do
      {:ok, envelope, parsed}
    end
  end

  @doc """
  Loads a database envelope and validates it against the registered definition.

  A type mismatch between the envelope and the definition is a storage error.
  It means the row exists but does not satisfy the key contract, so callers must
  not treat it as missing.
  """
  @spec load(definition(), String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def load(definition, scope, key, envelope) do
    case envelope_parts(envelope) do
      {:ok, @plaintext, value} -> load_plaintext(definition, value)
      {:ok, @cipher, value} -> load_cipher(definition, scope, key, value)
      {:ok, type, _value} -> {:error, {:unknown_envelope_type, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates a value through either an exact or pattern-backed definition.
  """
  @spec validate(definition(), term()) :: {:ok, term()} | {:error, term()}
  def validate(%Definition{} = definition, value), do: Definition.validate(definition, value)

  def validate(%PatternDefinition{} = definition, value),
    do: PatternDefinition.validate(definition, value)

  defp encode_envelope(%{encrypted: false}, _scope, _key, value) do
    {:ok, %{"type" => @plaintext, "value" => value}}
  end

  defp encode_envelope(%{encrypted: true}, scope, key, value) do
    with {:ok, ciphertext} <- Crypto.seal(value, scope, key) do
      {:ok, %{"type" => @cipher, "value" => ciphertext}}
    end
  end

  # Plaintext and cipher envelopes use the same outer shape. The registered
  # definition decides which type is acceptable for the key.
  defp load_plaintext(%{encrypted: false} = definition, value), do: validate(definition, value)
  defp load_plaintext(%{encrypted: true}, _value), do: {:error, :expected_cipher}

  defp load_cipher(%{encrypted: false}, _scope, _key, _value), do: {:error, :expected_plaintext}

  defp load_cipher(%{encrypted: true} = definition, scope, key, value) when is_binary(value) do
    with {:ok, decrypted} <- Crypto.unseal(value, scope, key) do
      validate(definition, decrypted)
    end
  end

  defp load_cipher(%{encrypted: true}, _scope, _key, _value),
    do: {:error, :expected_cipher_string}

  defp envelope_parts(%{"type" => type, "value" => value}) when is_binary(type) do
    {:ok, type, value}
  end

  defp envelope_parts(%{type: type, value: value}) when is_binary(type) do
    {:ok, type, value}
  end

  defp envelope_parts(_envelope), do: {:error, :invalid_envelope}
end
