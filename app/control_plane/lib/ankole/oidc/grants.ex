defmodule Ankole.OIDC.Grants do
  @moduledoc false
  alias Ankole.OIDC
  alias Ankole.OIDC.{Claims, CodeStore, RefreshStore, Sessions, Tokens}
  alias Ankole.Repo
  @refresh_ttl 30 * 24 * 60 * 60

  def authorize(params, authentication) do
    Repo.transact_top_level(fn -> authorize_in_tx(params, authentication) end)
  end

  @doc """
  Issues an authorization code in the caller's transaction.

  `BrowserSessions.consume_authorization/4` runs its `issue` callback in its
  transaction, so that callback issues the code with this function.
  """
  def authorize_in_tx(params, authentication) do
    with :ok <-
           Ankole.Principals.HumanAccess.check(
             authentication["principal_uid"],
             authentication["access_version"]
           ),
         {:ok, session} <-
           Sessions.ensure_in_tx(params["client_id"], authentication, params["scope"]),
         {:ok, code} <-
           Attesto.AuthorizationCode.issue(CodeStore, %{
             client_id: params["client_id"],
             redirect_uri: params["redirect_uri"],
             code_challenge: params["code_challenge"],
             subject: authentication["principal_uid"],
             scope: String.split(params["scope"], " ", trim: true),
             claims: %{"session_id" => session.id, "nonce" => params["nonce"]}
           }) do
      {:ok, code}
    end
  end

  def validate_type(%{"grant_type" => type}) when type in ["authorization_code", "refresh_token"],
    do: :ok

  def validate_type(%{"grant_type" => _}),
    do: {:error, "unsupported_grant_type", "grant_type is not supported"}

  def validate_type(_), do: {:error, "invalid_request", "grant_type is required"}

  def exchange(client, %{"grant_type" => "authorization_code", "code" => code} = params)
      when is_binary(code) do
    case Attesto.AuthorizationCode.redeem(CodeStore, code, %{
           redirect_uri: params["redirect_uri"],
           code_verifier: params["code_verifier"],
           client_id: client.id
         }) do
      {:ok, grant} ->
        issue_code_response(client, code, grant)

      {:error, {:reuse, meta}} ->
        :ok = RefreshStore.revoke_family(meta[:family_id])
        _ = Sessions.revoke(meta.session_id)
        invalid_grant()

      _ ->
        invalid_grant()
    end
  end

  def exchange(client, %{"grant_type" => "refresh_token", "refresh_token" => raw} = params)
      when is_binary(raw) do
    with {:ok, scopes} <- requested_refresh_scope(client, params),
         {:ok, rotated} <-
           Attesto.RefreshToken.rotate(RefreshStore, raw,
             client_id: client.id,
             scope: scopes,
             ttl: @refresh_ttl,
             rotation_grace_seconds: 10
           ) do
      case Repo.transact_top_level(fn -> refresh_in_tx(client, rotated) end) do
        {:ok, _} = result ->
          result

        _ ->
          :ok = RefreshStore.revoke_family(rotated.family_id)
          invalid_grant()
      end
    else
      {:error, "invalid_scope", _} = error -> error
      {:error, :invalid_scope} -> {:error, "invalid_scope", "scope exceeds the original grant"}
      _ -> invalid_grant()
    end
  end

  def exchange(_, %{"grant_type" => type})
      when type not in ["authorization_code", "refresh_token"],
      do: {:error, "unsupported_grant_type", "grant_type is not supported"}

  def exchange(_, _), do: {:error, "invalid_request", "grant credentials are required"}

  defp issue_code_response(client, code, grant) do
    case Repo.transact_top_level(fn -> exchange_code_in_tx(client, code, grant) end) do
      {:ok, _} = result -> result
      _ -> invalid_grant()
    end
  end

  @doc false
  def exchange_code_in_tx(client, code, grant) do
    scope = Enum.join(grant.scope, " ")

    with {:ok, session, principal, human} <-
           validate_business(client.id, grant.subject, grant.claims["session_id"], scope, :code),
         {:ok, access} <- Tokens.mint_access(principal.uid, client.id, scope, session.id),
         {:ok, id_token} <-
           Attesto.IDToken.mint(OIDC.attesto_config(), principal.uid, client.id,
             sid: session.id,
             nonce: grant.claims["nonce"],
             auth_time: session.auth_time,
             access_token: access.token,
             extra_claims: Claims.project(principal, human, scope)
           ),
         {:ok, refresh} <- finalize(code, grant, session) do
      payload = response(access, scope) |> Map.put(:id_token, id_token)
      {:ok, if(refresh, do: Map.put(payload, :refresh_token, refresh), else: payload)}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  defp finalize(code, grant, session) do
    if "offline_access" in grant.scope do
      with {:ok, issued} <-
             Attesto.AuthorizationCode.issue_refresh_and_finalize(
               CodeStore,
               code,
               grant,
               RefreshStore,
               %{
                 subject: grant.subject,
                 client_id: grant.client_id,
                 scope: grant.scope,
                 auth_time: session.auth_time,
                 claims: %{"session_id" => session.id}
               },
               ttl: @refresh_ttl,
               family_ttl: @refresh_ttl
             ) do
        {:ok, issued.token}
      end
    else
      :ok = Attesto.AuthorizationCode.finalize(CodeStore, code, grant)
      {:ok, nil}
    end
  end

  @doc false
  def refresh_in_tx(client, rotated) do
    ctx = rotated.context
    scope = Enum.join(ctx.scope, " ")

    with {:ok, session, principal, _} <-
           validate_business(client.id, ctx.subject, ctx.claims["session_id"], scope, :refresh),
         {:ok, access} <- Tokens.mint_access(principal.uid, client.id, scope, session.id) do
      {:ok, response(access, scope) |> Map.put(:refresh_token, rotated.token)}
    end
  end

  defp validate_business(client_id, subject, sid, scope, kind) do
    with {:ok, principal, human} <- Claims.load(subject),
         {:ok, session} <- Sessions.validate(sid, client_id, subject, scope, kind),
         :ok <- gateway(client_id, subject, scope) do
      {:ok, session, principal, human}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def gateway(id, subject, scope) do
    if MapSet.member?(scope_set(scope), "ai_gateway.write") do
      with {:ok, _} <- OIDC.authorize_ai_gateway(id, subject), do: :ok
    else
      :ok
    end
  end

  defp requested_refresh_scope(_client, params) when not is_map_key(params, "scope"),
    do: {:ok, nil}

  defp requested_refresh_scope(client, %{"scope" => scope}) when is_binary(scope) do
    scopes = String.split(scope, " ", trim: true)

    if "openid" in scopes and MapSet.subset?(MapSet.new(scopes), MapSet.new(client.scopes)),
      do: {:ok, scopes},
      else: {:error, "invalid_scope", "scope must include openid and be allowed by the Client"}
  end

  defp requested_refresh_scope(_, _), do: {:error, "invalid_scope", "scope is invalid"}

  defp response(access, scope),
    do: %{
      access_token: access.token,
      token_type: "Bearer",
      expires_in: access.expires_at - DateTime.to_unix(access.inserted_at),
      scope: scope
    }

  defp scope_set(scope), do: scope |> String.split(" ", trim: true) |> MapSet.new()

  defp invalid_grant,
    do: {:error, "invalid_grant", "authorization grant is invalid, revoked, or expired"}
end
