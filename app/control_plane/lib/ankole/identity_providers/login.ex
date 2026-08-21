defmodule Ankole.IdentityProviders.Login do
  @moduledoc """
  Login boundary for configured identity providers.

  Login availability is one host-owned decision. For OIDC the adapter must
  declare the OIDC capability and the provider config must not turn
  `oidc.enabled` off; for the built-in password adapter the capability alone
  decides. The login list, the authorization redirect, and the code exchange
  all apply this same decision, so a sync-only provider never appears as a
  login option and adapters do not repeat the check. The password verify flow
  itself lives in `Ankole.IdentityProviders.LocalPassword`.
  """

  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.LocalPassword

  @authorization_capability "oidc_authorization"
  @code_exchange_capability "oidc_code_exchange"

  @doc """
  Lists configured providers available to the login page.

  Each entry carries a `"kind"` of `"password"` or `"oidc"` so the login page
  knows which interaction the provider needs.
  """
  @spec list_login_providers() :: {:ok, [map()]} | {:error, term()}
  def list_login_providers do
    with {:ok, providers} <- Config.active_providers() do
      {:ok,
       providers
       |> Enum.map(fn provider -> {provider, login_kind(provider)} end)
       |> Enum.reject(fn {_provider, kind} -> is_nil(kind) end)
       |> Enum.map(fn {provider, kind} -> Map.put(provider, "kind", kind) end)}
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

  defp login_kind(provider) do
    with true <- provider["enabled"] != false,
         {:ok, adapter} <- IdentityProviders.fetch_adapter(provider["adapter_id"]) do
      capabilities = IdentityProviders.adapter_capabilities(adapter)

      cond do
        LocalPassword.capability() in capabilities -> "password"
        @authorization_capability in capabilities -> oidc_login_kind(provider, adapter)
        true -> nil
      end
    else
      _disabled_or_unknown -> nil
    end
  end

  defp oidc_login_kind(provider, adapter) do
    case IdentityProviders.provider_config(provider) do
      {:ok, config} ->
        case ensure_login(adapter, config, @authorization_capability) do
          :ok -> "oidc"
          {:error, _reason} -> nil
        end

      _missing_or_error ->
        nil
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
