defmodule Ankole.AIGateway.ProviderConfigs.Projection do
  @moduledoc """
  Calculates the operator fields of an AIGateway provider.

  `credential_pool` gives `Ankole.AIGateway.ProviderConfigs.CredentialPoolView`.
  `provider_metadata` gives the capabilities and settings of the provider kind.
  """
  use Ash.Resource.Calculation

  alias Ankole.AIGateway.ProviderConfigs

  @impl true
  def init(opts) do
    if opts[:field] in [:credential_pool, :provider_metadata],
      do: {:ok, opts},
      else: {:error, "field must be :credential_pool or :provider_metadata"}
  end

  @impl true
  def load(_query, opts, _context) do
    case opts[:field] do
      :credential_pool -> [:id, :credential_pool]
      :provider_metadata -> [:provider_kind]
    end
  end

  @impl true
  def calculate(providers, opts, _context) do
    case opts[:field] do
      :credential_pool ->
        {:ok, Enum.map(providers, &ProviderConfigs.credential_pool_projection/1)}

      :provider_metadata ->
        {:ok, Enum.map(providers, &ProviderConfigs.provider_metadata(&1.provider_kind))}
    end
  end
end
