defmodule Ankole.Connectors.Resolver do
  @moduledoc false
  alias Ankole.Connectors.{Accounts, Credentials, OAuth, Registry, Store}

  def resolve_call(spec, actor, connection, account_key, args \\ %{}) do
    with :ok <- Store.member(actor),
         {:ok, module, _tools} <- Registry.toolkit(spec.toolkit),
         {:ok, config} <- Store.get_auth_config(connection, Registry.plugin_id(spec.toolkit)),
         human <- human(actor),
         :ok <- subject(spec.subject_policy, human),
         credential_spec = credential_spec(module, spec, human, args),
         {:ok, account, external_user_id} <-
           account(credential_spec, config, module, human, account_key),
         :ok <- require_account(config, account, human, module),
         :ok <- scopes(spec, account, module, config),
         {:ok, access_token} <- access_token(config, account, module) do
      {:ok,
       %{
         actor: actor,
         auth_config: config,
         account: account,
         access_token: access_token,
         external_user_id: external_user_id
       }}
    else
      {:error, :oauth_consent_required} ->
        OAuth.consent_required(connection_slug(spec, connection), spec.scopes || [], %{
          "toolkit" => spec.toolkit
        })

      error ->
        error
    end
  end

  defp access_token(config, %{subject_kind: "human"} = account, adapter) do
    case Credentials.access_token(config, account, adapter) do
      {:error, :oauth_reauthorization_required} -> {:error, :oauth_consent_required}
      result -> result
    end
  end

  defp access_token(config, account, adapter),
    do: Credentials.access_token(config, account, adapter)

  defp require_account(config, nil, human, adapter) do
    if config.auth_scheme == "oauth2" or not function_exported?(adapter, :fetch_app_token, 3) do
      {:error, if(human, do: :oauth_consent_required, else: :connection_account_required)}
    else
      :ok
    end
  end

  defp require_account(_config, _account, _human, _adapter), do: :ok

  defp credential_spec(adapter, spec, human, args) do
    if function_exported?(adapter, :upstream_auth, 3),
      do: %{spec | upstream_auth: adapter.upstream_auth(spec, human, args)},
      else: spec
  end

  defp connection_slug(spec, selector) do
    case Store.get_auth_config(selector, Registry.plugin_id(spec.toolkit)) do
      {:ok, config} -> config.slug
      _ -> selector || ""
    end
  end

  defp human(%{uid: uid}) do
    authority = Ankole.Principals.authority_uid(uid)

    case Ankole.Principals.get_principal(authority) do
      {:ok, %{type: :human, status: :active} = principal} -> principal
      _ -> nil
    end
  end

  defp subject(:human_authority, nil), do: {:error, :human_authority_required}
  defp subject(_, _), do: :ok

  defp account(%{upstream_auth: auth}, _config, _adapter, nil, _key)
       when auth in [:app_token_with_bound_user, :human_oauth_token],
       do: {:error, :human_authority_required}

  defp account(%{upstream_auth: :app_token_with_bound_user}, config, adapter, human, _key) do
    with {:ok, user_id} <- adapter.bound_user_id(config, human.uid),
         do: {:ok, nil, user_id}
  end

  defp account(%{upstream_auth: :human_oauth_token}, config, _adapter, human, _key) do
    with {:ok, account} <- Accounts.get_account(config.id, "human", human.uid) do
      if account && Accounts.valid?(account),
        do: {:ok, account, account.external_subject_id},
        else: {:error, :oauth_consent_required}
    end
  end

  defp account(%{upstream_auth: :adaptive_token}, config, _adapter, _human, key)
       when not is_nil(key),
       do: app_account(config, key)

  defp account(%{upstream_auth: :adaptive_token} = spec, config, adapter, human, key)
       when not is_nil(human) do
    with {:ok, personal} <- Accounts.get_account(config.id, "human", human.uid) do
      cond do
        personal && Accounts.valid?(personal) && scopes(spec, personal, adapter, config) == :ok ->
          {:ok, personal, personal.external_subject_id}

        function_exported?(adapter, :bound_user_id, 2) ->
          case adapter.bound_user_id(config, human.uid) do
            {:ok, user_id} ->
              with {:ok, app, _} <- app_account(config, key), do: {:ok, app, user_id}

            _ when not is_nil(personal) ->
              {:error, :oauth_consent_required}

            _ ->
              app_account(config, key)
          end

        personal ->
          {:error, :oauth_consent_required}

        true ->
          app_account(config, key)
      end
    end
  end

  defp account(_, config, _adapter, _human, key), do: app_account(config, key)

  defp app_account(config, key) do
    with {:ok, account} <- Accounts.application_account(config, key),
         do: {:ok, account, nil}
  end

  defp scopes(
         %{scopes: required},
         %{subject_kind: "human", granted_scopes: granted},
         adapter,
         config
       ) do
    permitted =
      if function_exported?(adapter, :scopes_satisfied?, 3),
        do: adapter.scopes_satisfied?(required || [], granted, config),
        else: Enum.all?(required || [], &(&1 in granted))

    if permitted, do: :ok, else: {:error, :oauth_consent_required}
  end

  defp scopes(_, _, _, _), do: :ok
end
