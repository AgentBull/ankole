defmodule Ankole.OIDC.Boruta.AccessTokens do
  @moduledoc false

  @behaviour Boruta.Oauth.AccessTokens

  import Ecto.Query, warn: false

  alias Ankole.OIDC
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.Boruta.Clients
  alias Ankole.OIDC.Boruta.ResourceOwners
  alias Ankole.OIDC.Boruta.TokenGenerator
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.RefreshToken
  alias Ankole.OIDC.Tokens
  alias Ankole.Repo
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.Token

  @offline_access "offline_access"
  @ai_gateway_scope "ai_gateway.write"

  @impl true
  def get_by(value: value) when is_binary(value) do
    with {:ok, claims} <- Tokens.verify_access(value, Tokens.userinfo_audience()),
         %{"client_id" => client_id, "sub" => sub, "scope" => scope, "exp" => expires_at} <-
           claims,
         client when not is_nil(client) <- Clients.get_client(client_id),
         true <- requested_scope_allowed?(scope, client_scope(client)),
         {:ok, resource_owner} <- ResourceOwners.load(sub),
         {:ok, inserted_at} <- timestamp(claims["iat"]) do
      %Token{
        type: "access_token",
        value: value,
        scope: scope,
        expires_at: expires_at,
        client: client,
        sub: sub,
        resource_owner: resource_owner,
        inserted_at: inserted_at
      }
    else
      _invalid -> nil
    end
  end

  def get_by(refresh_token: raw) when is_binary(raw) do
    case Repo.get(RefreshToken, TokenGenerator.digest(raw)) do
      %RefreshToken{} = row -> refresh_from_row(row, raw)
      nil -> nil
    end
  end

  def get_by(_params), do: nil

  @impl true
  def create(params, opts) when is_map(params) and is_list(opts) do
    issue_refresh? =
      Keyword.get(opts, :refresh_token, false) and scope?(params[:scope], @offline_access)

    result =
      Repo.transact(fn repo ->
        with {:ok, current_client} <- ensure_current_client(repo, params.client.id),
             :ok <- ensure_current_scope(current_client, params.scope),
             {:ok, rotation} <- consume_previous_credential(repo, params),
             :ok <- ensure_current_gateway_access(params.client.id, params.sub, params.scope),
             {:ok, resource_owner} <- current_resource_owner(params.sub),
             {:ok, minted} <- Tokens.mint_access(params.sub, params.client.id, params.scope),
             {:ok, refresh_token} <-
               maybe_create_refresh(repo, params, rotation, issue_refresh?) do
          {:ok,
           %Token{
             type: "access_token",
             value: minted.token,
             state: params[:state],
             scope: params.scope,
             redirect_uri: params[:redirect_uri],
             expires_at: minted.expires_at,
             client: params.client,
             sub: params.sub,
             resource_owner: resource_owner,
             refresh_token: refresh_token,
             inserted_at: minted.inserted_at
           }}
        end
      end)

    normalize_grant_result(result)
  end

  @impl true
  def revoke(%Token{} = token), do: {:ok, %{token | revoked_at: DateTime.utc_now()}}

  @impl true
  def revoke_refresh_token(%Token{} = token) do
    raw = token.refresh_token || token.value

    if is_binary(raw) do
      _ =
        Repo.delete_all(
          from refresh in RefreshToken, where: refresh.digest == ^TokenGenerator.digest(raw)
        )
    end

    {:ok, %{token | refresh_token_revoked_at: DateTime.utc_now()}}
  end

  defp consume_previous_credential(repo, %{previous_code: raw} = params)
       when is_binary(raw) do
    digest = TokenGenerator.digest(raw)

    case repo.delete_all(
           from(code in AuthorizationCode,
             where:
               code.digest == ^digest and code.client_id == ^params.client.id and
                 code.principal_uid == ^params.sub and code.redirect_uri == ^params.redirect_uri and
                 code.expires_at > ^DateTime.utc_now(),
             select: code
           ),
           returning: true
         ) do
      {1, [_row]} -> {:ok, :initial}
      _missing_or_replayed -> {:error, :authorization_code_already_used}
    end
  end

  defp consume_previous_credential(repo, %{previous_token: raw} = params)
       when is_binary(raw) do
    digest = TokenGenerator.digest(raw)

    case repo.delete_all(
           from(refresh in RefreshToken,
             where:
               refresh.digest == ^digest and refresh.client_id == ^params.client.id and
                 refresh.principal_uid == ^params.sub and
                 refresh.absolute_expires_at > ^DateTime.utc_now(),
             select: refresh
           ),
           returning: true
         ) do
      {1, [row]} ->
        if requested_scope_allowed?(params.scope, row.scope),
          do: {:ok, {:rotation, row}},
          else: {:error, :invalid_refresh_scope}

      _missing_or_replayed ->
        {:error, :refresh_token_already_used}
    end
  end

  defp consume_previous_credential(_repo, _params), do: {:ok, :initial}

  defp maybe_create_refresh(_repo, _params, _rotation, false), do: {:ok, nil}

  defp maybe_create_refresh(repo, params, rotation, true) do
    raw = TokenGenerator.opaque_token()
    {issued_at, absolute_expires_at} = refresh_window(params.client, rotation)

    %RefreshToken{}
    |> RefreshToken.changeset(%{
      digest: TokenGenerator.digest(raw),
      client_id: params.client.id,
      principal_uid: params.sub,
      scope: params.scope,
      issued_at: issued_at,
      absolute_expires_at: absolute_expires_at
    })
    |> repo.insert()
    |> case do
      {:ok, _row} -> {:ok, raw}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_window(_client, {:rotation, row}),
    do: {row.issued_at, row.absolute_expires_at}

  defp refresh_window(client, :initial) do
    now = DateTime.utc_now()
    {now, DateTime.add(now, client.refresh_token_ttl, :second)}
  end

  defp refresh_from_row(row, raw) do
    with :gt <- DateTime.compare(row.absolute_expires_at, DateTime.utc_now()),
         client when not is_nil(client) <- Clients.get_client(row.client_id),
         {:ok, resource_owner} <- ResourceOwners.load(row.principal_uid) do
      %Token{
        type: "access_token",
        value: raw,
        scope: row.scope,
        expires_at: DateTime.to_unix(row.absolute_expires_at),
        client: client,
        sub: row.principal_uid,
        resource_owner: resource_owner,
        refresh_token: raw,
        inserted_at: row.issued_at
      }
    else
      _invalid -> nil
    end
  end

  defp ensure_current_client(repo, client_id) do
    case repo.get_by(Client, id: client_id, enabled: true) do
      %Client{} = client -> {:ok, client}
      nil -> {:error, :client_disabled}
    end
  end

  defp ensure_current_scope(%Client{scopes: scopes}, requested_scope) do
    if requested_scope_allowed?(requested_scope, Enum.join(scopes, " ")),
      do: :ok,
      else: {:error, :scope_revoked}
  end

  defp ensure_current_gateway_access(client_id, principal_uid, scope) do
    if scope?(scope, @ai_gateway_scope) do
      case OIDC.authorize_ai_gateway(client_id, principal_uid) do
        {:ok, _client} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp current_resource_owner(principal_uid) do
    case ResourceOwners.load(principal_uid) do
      {:ok, resource_owner} -> {:ok, resource_owner}
      {:error, _reason} -> {:error, :inactive_human}
    end
  end

  defp requested_scope_allowed?(requested, original) do
    MapSet.subset?(scope_set(requested), scope_set(original))
  end

  defp client_scope(client) do
    client.authorized_scopes
    |> Enum.map(& &1.name)
    |> Enum.join(" ")
  end

  defp scope?(scope, name), do: MapSet.member?(scope_set(scope), name)

  defp scope_set(scope) when is_binary(scope),
    do: scope |> String.split(" ", trim: true) |> MapSet.new()

  defp scope_set(_scope), do: MapSet.new()

  defp timestamp(value) when is_integer(value), do: DateTime.from_unix(value)
  defp timestamp(_value), do: {:error, :invalid_iat}

  defp normalize_grant_result({:error, reason})
       when reason in [
              :authorization_code_already_used,
              :refresh_token_already_used,
              :invalid_refresh_scope,
              :client_disabled,
              :scope_revoked,
              :inactive_human,
              :group_not_allowed,
              :model_not_allowed,
              :not_found
            ] do
    {:error,
     %Error{
       status: :bad_request,
       error: :invalid_grant,
       error_description: "Given authorization grant is invalid, revoked, or expired."
     }}
  end

  defp normalize_grant_result(result), do: result
end
