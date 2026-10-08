defmodule Ankole.SignalsGateway.SubjectNamespace do
  @moduledoc """
  Resolves the Principal subject namespace of one enterprise IM binding.

  Adapters declare an `identityProvider` field of type `identity_provider`
  that names their identity-provider adapter. The stored reference, the
  binding catalog, and the save-time validation all follow one rule:

  - an identity provider id names that provider's namespace;
  - `standalone_reference/0` keeps the adapter's own default namespace;
  - no reference adopts the single configured provider of the adapter, and
    falls back to the adapter default when there is none or several.

  Saving a binding rejects a missing reference while several providers exist,
  so the fallback is never silently ambiguous. A disabled provider still owns
  its namespace, so configured providers count regardless of their flag.
  """

  alias Ankole.IdentityProviders

  @standalone ":standalone"

  @doc """
  Returns the reference value that keeps the adapter default namespace.
  """
  @spec standalone_reference() :: String.t()
  def standalone_reference, do: @standalone

  @doc """
  Resolves the namespace for one chat config reference.
  """
  @spec resolve(String.t(), String.t() | nil, String.t()) :: String.t()
  def resolve(_identity_adapter_id, @standalone, default), do: default

  def resolve(_identity_adapter_id, reference, _default)
      when is_binary(reference) and reference != "",
      do: reference

  def resolve(identity_adapter_id, _reference, default) do
    case provider_ids(identity_adapter_id) do
      {:ok, [single]} -> single
      _none_or_several -> default
    end
  end

  @doc """
  Lists the configured provider ids of one identity-provider adapter, sorted.
  """
  @spec provider_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def provider_ids(identity_adapter_id) do
    with {:ok, refs} <- IdentityProviders.list_provider_refs(identity_adapter_id) do
      {:ok, refs |> Enum.map(& &1["provider_id"]) |> Enum.sort()}
    end
  end
end
