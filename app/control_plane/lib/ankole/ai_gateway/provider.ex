defmodule Ankole.AIGateway.Provider do
  @moduledoc """
  Behaviour for AIGateway provider implementations.

  Provider modules use `Ankole.AIGateway.ProviderDSL` to compile this definition.
  Request preparation stays in the provider module as normal Elixir code, while
  response normalization and transport execution are delegated to the native
  UniversalAIClient.
  """

  @doc "Returns the compiled provider definition."
  @callback provider_definition() :: Ankole.AIGateway.ProviderDefinition.t()

  @doc "Returns a provider-specific metadata source descriptor when one exists."
  @callback models_metadata_source(map()) :: {:ok, term()} | {:error, term()}

  @doc "Validates provider-specific connection options when the provider defines this hook."
  @callback validate_connection_options(map()) :: :ok | {:error, term()}

  @doc "Validates provider-specific credential options when the provider defines this hook."
  @callback validate_credential_options(map()) :: :ok | {:error, term()}

  @doc """
  Describes the endpoint that serves an image model for one `image_generation`
  tool, or names what the model cannot serve: the model itself, or the public
  tool field at fault (`input` for reference images).
  """
  @callback image_endpoint(
              model :: String.t(),
              tool :: map(),
              reference_count :: non_neg_integer()
            ) ::
              {:ok, map()} | {:error, :unknown_model | {:unsupported_field, String.t()}}

  @optional_callbacks models_metadata_source: 1,
                      image_endpoint: 3,
                      validate_connection_options: 1,
                      validate_credential_options: 1
end
