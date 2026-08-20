defmodule Ankole.IdentityProviders.Login do
  @moduledoc """
  OIDC login boundary for configured identity providers.

  Login availability is one host-owned decision: the adapter must declare the
  OIDC capability, and the provider config must not turn `oidc.enabled` off.
  The login list, the authorization redirect, and the code exchange all apply
  this same decision, so a sync-only provider never appears as a login option
  and adapters do not repeat the check.
  """

  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config

  @authorization_capability "oidc_authorization"
  @code_exchange_capability "oidc_code_exchange"

  @doc """
  Lists configured providers available to the login page.
  """
  @spec list_login_providers() :: {:ok, [map()]} | {:error, term()}
  def list_login_providers do
    with {:ok, providers} <- Config.active_providers() do
      {:ok, Enum.filter(providers, &login_provider?/1)}
    end
  end

  @doc """
  Builds an OIDC authorization URL for one configured provider.
  """
  @spec authorization_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(provider_id, opts) when is_binary(provider_id) and is_list(opts) do
    with {:ok, module, config} <- login_module(provider_id, @authorization_capability) do
      module.authorization_url(config, opts)
    end
  end

  @doc """
  Exchanges an OIDC authorization code and upserts the authenticated user.
  """
  @spec complete_oidc_login(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_oidc_login(provider_id, code, opts)
      when is_binary(provider_id) and is_binary(code) and is_list(opts) do
    with {:ok, module, config} <- login_module(provider_id, @code_exchange_capability),
         {:ok, %{user: user}} <- module.exchange_code(config, code, opts),
         {:ok, %{principal: principal, identity: identity}} <-
           module.upsert_user(provider_id, user) do
      {:ok,
       %{
         principal_uid: principal.uid,
         provider_id: provider_id,
         external_id: identity.external_id,
         user: user
       }}
    end
  end

  @doc """
  Returns the callback path used for OIDC providers.
  """
  @spec oidc_callback_path(String.t()) :: String.t()
  def oidc_callback_path(provider_id) do
    "/sessions/oidc/#{URI.encode(provider_id)}/callback"
  end

  @doc """
  Returns the absolute redirect URI for one provider and public base URL.
  """
  @spec oidc_redirect_uri(String.t(), String.t()) :: String.t()
  def oidc_redirect_uri(public_base_url, provider_id) do
    String.trim_trailing(public_base_url, "/") <> oidc_callback_path(provider_id)
  end

  defp login_module(provider_id, capability) do
    with {:ok, provider} <- IdentityProviders.fetch_active_provider(provider_id),
         {:ok, adapter} <- IdentityProviders.fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- IdentityProviders.provider_config(provider),
         :ok <- ensure_login(adapter, config, capability),
         {:ok, module} <- IdentityProviders.adapter_module(adapter) do
      {:ok, module, config}
    end
  end

  defp login_provider?(provider) do
    with true <- provider["enabled"] != false,
         {:ok, adapter} <- IdentityProviders.fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- IdentityProviders.provider_config(provider) do
      ensure_login(adapter, config, @authorization_capability) == :ok
    else
      _other -> false
    end
  end

  defp ensure_login(adapter, config, capability) do
    cond do
      capability not in IdentityProviders.adapter_capabilities(adapter) ->
        {:error, :oidc_unsupported}

      get_in(config, ["oidc", "enabled"]) == false ->
        {:error, :oidc_disabled}

      true ->
        :ok
    end
  end
end
