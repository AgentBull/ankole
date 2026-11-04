defmodule Ankole.Connectors.Credentials do
  @moduledoc false
  alias Ankole.Connectors.{Accounts, AppTokenCache, Store, TokenRefresher}

  def seal(value, purpose, id),
    do:
      Ankole.SecretKeyBase.seal(Ankole.JSON.encode!(value), purpose, [
        Ankole.Repo.tenant_id!(),
        id
      ])

  def unseal(value, purpose, id) do
    with {:ok, json} <-
           Ankole.SecretKeyBase.unseal(value, purpose, [Ankole.Repo.tenant_id!(), id]),
         do: Ankole.JSON.decode(json)
  end

  def secret(config), do: unseal(config.sealed_secret, "connector_auth_config", config.id)

  def resolve_credentials(id) do
    with {:ok, config} <- Store.get_auth_config(id), do: secret(config)
  end

  def account_credentials(account),
    do: unseal(account.sealed_credentials, "connector_connected_account", account.id)

  def subscription_token(config, account, adapter, true),
    do: access_token(config, account, adapter)

  def subscription_token(_config, %{sealed_credentials: credentials} = account, _adapter, false)
      when is_binary(credentials) do
    with {:ok, tokens} <- account_credentials(account), do: {:ok, tokens["access_token"]}
  end

  def subscription_token(config, account, adapter, false),
    do: AppTokenCache.get(config, account, adapter)

  def access_token(config, account, adapter) do
    with {:ok, latest} <- Store.get_auth_config(config.id),
         {:ok, account} <- if(account, do: Accounts.get_by_id(account.id), else: {:ok, nil}),
         true <- is_nil(account) or Accounts.valid?(account) do
      if account && account.sealed_credentials do
        TokenRefresher.access_token(latest, account, adapter)
      else
        AppTokenCache.get(latest, account, adapter)
      end
    else
      false -> {:error, :oauth_reauthorization_required}
      error -> error
    end
  end

  def invalidate_access_token(config, %{sealed_credentials: credentials} = account, token)
      when is_binary(credentials),
      do: TokenRefresher.invalidate(config, account, token)

  def invalidate_access_token(config, account, token),
    do: AppTokenCache.invalidate(config, account, token)

  def refresh_rejected_token(config, account, token, adapter) do
    with result when result in [:ok, {:ok, :ok}] <-
           invalidate_access_token(config, account, token),
         do: access_token(config, account, adapter)
  end
end
