defmodule Ankole.AppConfigure.Codec do
  @moduledoc """
  Converts AppConfigure runtime values to and from database envelopes.
  """

  alias Ankole.AppConfigure.Crypto
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Envelope
  alias Ankole.AppConfigure.PatternDefinition

  @type definition :: Definition.t() | PatternDefinition.t()

  @doc "Reads persisted configuration for editing, including references to disabled connections."
  def read_configuration(key) do
    with {:ok, definition} <- Ankole.AppConfigure.Registry.require_key(key),
         {:ok, scope, envelope} <- configuration_envelope(definition, key),
         {:ok, config} <- decode_envelope(definition, scope, key, envelope) do
      validate(definition, config, :configuration)
    end
  end

  defp configuration_envelope(%{scope: :global}, key), do: global_configuration(key)

  defp configuration_envelope(definition, key) do
    scope = "tenant:" <> Ankole.Repo.tenant_id!()

    with {:ok, row} <- Ankole.AppConfigure.get_app_config(scope, key) do
      case row do
        %{value: envelope} -> {:ok, scope, envelope}
        nil when definition.scope == :pod -> :error
        nil -> global_configuration(key)
      end
    end
  end

  defp global_configuration(key) do
    case Ankole.AppConfigure.get_site_config("global", key) do
      {:ok, %{value: envelope}} -> {:ok, "global", envelope}
      {:ok, nil} -> :error
      error -> error
    end
  end

  @doc """
  Validates a runtime value and converts it into a database envelope.

  Validation runs before encryption so encrypted rows store only schema-approved
  JSON values, not arbitrary Elixir terms.
  """
  @spec dump(definition(), String.t(), String.t(), term()) ::
          {:ok, map(), term()} | {:error, term()}
  def dump(definition, scope, key, value) do
    with {:ok, parsed} <- validate(definition, value, :configuration),
         {:ok, envelope} <-
           encode_envelope(
             definition,
             scope,
             key,
             Ankole.Connectors.LegacyConfig.stored(definition, parsed)
           ) do
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
  def load(definition, scope, key, envelope, mode \\ :runtime) do
    with {:ok, value} <- decode_envelope(definition, scope, key, envelope),
         do: validate(definition, value, mode)
  end

  defp decode_envelope(definition, scope, key, envelope) do
    case Envelope.parts(envelope) do
      {:ok, :plaintext, value} -> load_plaintext(definition, value)
      {:ok, :cipher, value} -> load_cipher(definition, scope, key, value)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates a value through either an exact or pattern-backed definition.
  """
  @spec validate(definition(), term()) :: {:ok, term()} | {:error, term()}
  def validate(definition, value, mode \\ :runtime)

  def validate(%Definition{} = definition, value, mode),
    do:
      Ankole.Connectors.LegacyConfig.validate(
        definition,
        value,
        &Definition.validate(definition, &1),
        mode
      )

  def validate(%PatternDefinition{} = definition, value, mode),
    do:
      Ankole.Connectors.LegacyConfig.validate(
        definition,
        value,
        &PatternDefinition.validate(definition, &1),
        mode
      )

  defp encode_envelope(%{encrypted: false}, _scope, _key, value) do
    {:ok, Envelope.plaintext(value)}
  end

  defp encode_envelope(%{encrypted: true}, scope, key, value) do
    with {:ok, ciphertext} <- Crypto.seal(value, scope, key) do
      {:ok, Envelope.cipher(ciphertext)}
    end
  end

  # Plaintext and cipher envelopes use the same outer shape. The registered
  # definition decides which type is acceptable for the key.
  defp load_plaintext(%{encrypted: false}, value), do: {:ok, value}
  defp load_plaintext(%{encrypted: true}, _value), do: {:error, :expected_cipher}

  defp load_cipher(%{encrypted: false}, _scope, _key, _value), do: {:error, :expected_plaintext}

  defp load_cipher(%{encrypted: true}, scope, key, value) when is_binary(value),
    do: Crypto.unseal(value, scope, key)

  defp load_cipher(%{encrypted: true}, _scope, _key, _value),
    do: {:error, :expected_cipher_string}
end
