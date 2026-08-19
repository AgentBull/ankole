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

  @doc "Prepares a provider-owned live connection check."
  @callback prepare_connection_check(map()) ::
              {:ok, Ankole.AIGateway.ProviderConnectionCheck.t()} | {:error, term()}

  @doc "Validates semantic constraints across connection settings."
  @callback validate_connection_options(map()) :: :ok | {:error, term()}

  @optional_callbacks models_metadata_source: 1,
                      prepare_connection_check: 1,
                      validate_connection_options: 1
end
