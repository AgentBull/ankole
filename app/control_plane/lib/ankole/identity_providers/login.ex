defmodule Ankole.IdentityProviders.Login do
  @moduledoc "Enterprise login availability, upstream proof verification, and member admission."

  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.OIDC

  @authorization_capability "oidc_authorization"
  @code_exchange_capability "oidc_code_exchange"

  @doc """
  Lists configured providers available to the login page.

  Each entry carries a `"kind"` of `"oidc"` so the login page
  knows which interaction the provider needs.
  """
  @spec list_login_providers() :: {:ok, [map()]} | {:error, term()}
  def list_login_providers do
    with {:ok, providers} <- Config.active_providers() do
      {:ok,
       providers
       |> Enum.map(fn provider -> {provider, login_kind(provider)} end)
       |> Enum.reject(fn {_provider, kind} -> is_nil(kind) end)
       |> Enum.map(fn {provider, kind} ->
         {:ok, adapter} = IdentityProviders.fetch_adapter(provider["adapter_id"])

         provider
         |> Map.put("kind", kind)
         |> Map.put("display_name", adapter.display_name)
         |> Map.put(
           "fresh_authentication",
           "oidc_fresh_authentication" in IdentityProviders.adapter_capabilities(adapter)
         )
       end)}
    end
  end

  @doc """
  Builds an OIDC authorization URL for one configured provider.
  """
  @spec authorization_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(provider_id, opts) when is_binary(provider_id) and is_list(opts) do
    with {:ok, module, config} <-
           login_module(provider_id, capability(opts, @authorization_capability)) do
      module.authorization_url(config, opts)
    end
  end

  @doc """
  Verifies the upstream proof before it starts a transaction. The transaction
  admits the member, accepts the invitation, and calls the optional completion
  function. A rejected invitation or completion commits none of those writes.
  """
  @spec complete_oidc_login(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_oidc_login(provider_id, code, opts)
      when is_binary(provider_id) and is_binary(code) and is_list(opts) do
    with {:ok, module, config} <-
           login_module(provider_id, capability(opts, @code_exchange_capability)),
         {:ok, %{user: _user} = login} <- module.exchange_code(config, code, opts),
         {:ok, auth_time} <-
           OIDC.verify_login(module.id_token_verification(config), login, opts),
         do: admit_login(module, provider_id, login, auth_time, opts)
  end

  defp admit_login(module, provider_id, login, auth_time, opts) do
    Ankole.Repo.transact_top_level(fn ->
      with :ok <- lock_browser(Keyword.get(opts, :browser_reference)),
           {:ok, invitation} <-
             Ankole.Principals.prepare_oidc_invitation_in_tx(
               Keyword.get(opts, :invitation_id),
               login
             ),
           {:ok, %{principal: principal, identity: identity} = observed} <-
             module.upsert_user_in_tx(
               provider_id,
               login.user,
               if(invitation, do: [membership: invitation.membership], else: [])
             ),
           :ok <- Ankole.Principals.HumanAccess.check(principal.uid, principal.access_version),
           {:ok, _} <- Ankole.Principals.accept_oidc_invitation_in_tx(invitation, observed) do
        result = %{
          principal_uid: principal.uid,
          access_version: principal.access_version,
          auth_time: auth_time,
          provider_id: provider_id,
          external_id: identity.external_id,
          user: login.user
        }

        Keyword.get(opts, :complete, &{:ok, &1}).(result)
      end
    end)
  end

  defp lock_browser(nil), do: :ok

  defp lock_browser(reference) do
    with {:ok, _} <- Ankole.BrowserSessions.lock_browser_in_tx(reference), do: :ok
  end

  defp capability(opts, ordinary) do
    if Keyword.get(opts, :auth_time_required, false),
      do: "oidc_fresh_authentication",
      else: ordinary
  end

  # Returns the callback path used for OIDC providers.
  #
  @spec oidc_callback_path(String.t()) :: String.t()
  defp oidc_callback_path(provider_id) do
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
