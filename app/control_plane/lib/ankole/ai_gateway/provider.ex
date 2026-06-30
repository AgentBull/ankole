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

  @doc "Performs a provider-owned live connection check."
  @callback check_connection(map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks models_metadata_source: 1, check_connection: 1
end
