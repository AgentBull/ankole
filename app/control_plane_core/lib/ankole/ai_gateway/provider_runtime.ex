defmodule Ankole.AIGateway.ProviderRuntime do
  @moduledoc """
  Provider runtime context for model metadata.

  Model requests use `PrepareContext`. Model metadata hooks use this smaller
  context because they do not run inside a stored Response or carry a public
  request body.
  """

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider

  @default_timeout_ms 15_000

  @doc """
  Builds the provider-facing helper context for model metadata hooks.

  The shape is intentionally map-based because built-in and plugin provider
  callbacks share it. `settings` preserves the existing top-level atom-key view
  of the decrypted runtime connection.
  """
  @spec context(Provider.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def context(%Provider{} = provider, opts \\ []) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    capability = Keyword.get(opts, :capability, "llm")

    with {:ok, connection} <- ProviderConfigs.runtime_connection(provider) do
      {:ok,
       %{
         provider_id: provider.provider_id,
         provider_kind: provider.provider_kind,
         capability: capability,
         connection: connection,
         settings: atomize_keys(connection),
         timeout_ms: timeout_ms,
         http_client: Keyword.get(opts, :http_client)
       }}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end
end
