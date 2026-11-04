defmodule Ankole.Connectors.OAuth do
  @moduledoc "Cookie-independent OAuth callback with authenticated, one-use connection claiming."
  require Ash.Query
  alias Ankole.Connectors.{Accounts, Credentials, OAuthSession, Registry, Store}
  alias Ankole.Authn.SecretDigest
  alias Ankole.Repo

  def cleanup_expired(now) do
    OAuthSession
    |> Ash.Query.filter(expires_at <= ^now)
    |> Ankole.Ash.destroy_where(:destroy)
  end

  def consent_required(connection, scopes, intent \\ %{}) do
    params =
      Map.merge(intent, %{
        "connection" => connection,
        "scopes" => Enum.join(scopes, " ")
      })

    {:error,
     %{
       code: "oauth_consent_required",
       retryable: false,
       connection: connection,
       scopes: scopes,
       authorization_url:
         AnkoleWeb.PodURL.current_tenant_url("/connectors") <> "?" <> URI.encode_query(params)
     }}
  end

  def begin(actor, attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)
    kind = attrs["subject_kind"] || "human"

    with :ok <- Store.member(actor),
         :ok <- authorize_kind(actor, kind),
         {:ok, config} <- Store.get_auth_config(attrs["connection"], attrs["plugin_id"]),
         {:ok, adapter} <- Registry.adapter(config.plugin_id),
         {:ok, secret} <- Credentials.secret(config) do
      id = Ankole.Kernel.gen_uuid_v7()
      state = Repo.tenant_id!() <> "." <> SecretDigest.token()
      verifier = SecretDigest.token()
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      scopes = requested_scopes(config, actor, kind, attrs["scopes"] || [])

      params = %{
        :subject_kind => kind,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "redirect_uri" => callback_url(),
        "scope" => Enum.join(scopes, " ")
      }

      with {:ok, url} <- adapter.oauth_authorize_url(config, secret, params),
           {:ok, sealed} <- Credentials.seal(verifier, "connector_oauth_pkce", id),
           {:ok, _session} <-
             Ankole.Ash.create(OAuthSession, :create, %{
               id: id,
               auth_config_id: config.id,
               subject_kind: kind,
               actor_uid: actor.uid,
               oauth_state_digest: SecretDigest.digest("connector_oauth_state", state),
               sealed_pkce_verifier: sealed,
               requested_scopes: scopes,
               return_to: safe_return_to(attrs["return_to"]),
               expires_at: DateTime.add(DateTime.utc_now(), 600)
             }) do
        {:ok, %{authorization_url: url, expires_in: 600}}
      end
    end
  end

  defp requested_scopes(config, actor, "human", requested) do
    case Accounts.get_account(config.id, "human", actor.uid) do
      {:ok, %{granted_scopes: granted}} -> Enum.uniq(granted ++ requested)
      _ -> requested
    end
  end

  defp requested_scopes(_config, _actor, _kind, requested), do: requested

  def callback(%{"state" => state, "code" => code} = params)
      when is_binary(state) and is_binary(code) do
    with [tenant, _] <- String.split(state, ".", parts: 2),
         {:ok, tenant} <- Ecto.UUID.cast(tenant) do
      Repo.with_tenant(tenant, fn -> complete_callback(state, code, params) end)
    else
      _ -> {:error, :invalid_oauth_state}
    end
  end

  def callback(%{"state" => state, "error" => error})
      when is_binary(state) and is_binary(error) do
    with [tenant, _] <- String.split(state, ".", parts: 2),
         {:ok, tenant} <- Ecto.UUID.cast(tenant) do
      Repo.with_tenant(tenant, fn ->
        with {:ok, session} <- take_callback(state) do
          {:ok,
           %{
             error: "oauth_authorization_cancelled",
             return_to: session.return_to,
             tenant_id: tenant
           }}
        end
      end)
    else
      _ -> {:error, :invalid_oauth_state}
    end
  end

  def callback(_), do: {:error, :oauth_authorization_failed}

  defp take_callback(state) do
    digest = SecretDigest.digest("connector_oauth_state", state)

    Repo.transact_top_level(fn ->
      session =
        OAuthSession
        |> Ash.Query.filter(oauth_state_digest == ^digest)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read_one!(lock_identity: {:rows, "connector_oauth_sessions", :id})

      case session do
        %{status: "pending"} ->
          if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
            Ankole.Ash.update(session, :update, %{status: "failed"})
          else
            {:error, :oauth_session_expired}
          end

        _ ->
          {:error, :invalid_oauth_state}
      end
    end)
  end

  defp complete_callback(state, code, params) do
    with {:ok, session} <- take_callback(state),
         {:ok, config} <- Store.get_auth_config(session.auth_config_id),
         {:ok, adapter} <- Registry.adapter(config.plugin_id),
         {:ok, secret} <- Credentials.secret(config),
         :ok <- issuer(config, params["iss"]),
         {:ok, verifier} <-
           Credentials.unseal(session.sealed_pkce_verifier, "connector_oauth_pkce", session.id),
         {:ok, tokens} <-
           adapter.oauth_exchange(config, secret, %{
             "code" => code,
             "code_verifier" => verifier,
             "redirect_uri" => callback_url()
           }),
         true <- is_binary(tokens["external_subject_id"]) and tokens["external_subject_id"] != "",
         completion = Repo.tenant_id!() <> "." <> SecretDigest.token(),
         {:ok, sealed} <- Credentials.seal(tokens, "connector_oauth_pending", session.id),
         {:ok, _} <-
           Ankole.Ash.update(session, :update, %{
             status: "callback_received",
             completion_code_digest:
               SecretDigest.digest("connector_oauth_completion", completion),
             sealed_pending_tokens: sealed,
             sealed_pkce_verifier: nil
           }) do
      {:ok,
       %{completion_code: completion, return_to: session.return_to, tenant_id: Repo.tenant_id!()}}
    else
      false -> {:error, :external_subject_required}
      error -> error
    end
  end

  def claim(actor, code) when is_binary(code) do
    with :ok <- Store.member(actor) do
      digest = SecretDigest.digest("connector_oauth_completion", code)

      session =
        OAuthSession
        |> Ash.Query.filter(completion_code_digest == ^digest)
        |> Ankole.Ash.read_one!()

      if session && session.actor_uid == actor.uid do
        Repo.transact_top_level(fn -> claim_in_tx(actor, session) end)
      else
        {:error, :invalid_oauth_completion}
      end
    end
  end

  def claim(_, _), do: {:error, :invalid_oauth_completion}

  defp claim_in_tx(actor, session) do
    with :ok <- authorize_kind(actor, session.subject_kind),
         :ok <-
           Ankole.Principals.WorkAccess.check_in_tx(
             Ankole.Principals.WorkAccess.from_sender(actor.uid)
           ),
         %{status: "active"} = config <- Store.lock(session.auth_config_id),
         %{status: "callback_received"} = locked <- lock(session.id),
         true <- DateTime.compare(locked.expires_at, DateTime.utc_now()) == :gt,
         {:ok, tokens} <-
           Credentials.unseal(
             locked.sealed_pending_tokens,
             "connector_oauth_pending",
             locked.id
           ),
         metadata = %{
           external_subject_id: tokens["external_subject_id"],
           public_metadata: tokens["public_metadata"] || %{},
           granted_scopes: scopes(tokens, locked.requested_scopes),
           owner_principal_uid: if(locked.subject_kind == "human", do: actor.uid),
           owner_access_version:
             if(locked.subject_kind == "human",
               do: Ankole.Principals.WorkAccess.from_sender(actor.uid).human_access_version
             )
         },
         {:ok, account} <-
           Accounts.put_tokens_in_tx(
             config,
             locked.subject_kind,
             if(locked.subject_kind == "human",
               do: actor.uid,
               else: tokens["external_subject_id"]
             ),
             tokens,
             metadata
           ),
         {:ok, _} <-
           Ankole.Ash.update(locked, :update, %{
             status: "completed",
             sealed_pending_tokens: nil,
             completion_code_digest: nil
           }) do
      {:ok, Accounts.public(account)}
    else
      {:error, _} = error -> error
      _ -> {:error, :oauth_session_expired}
    end
  end

  defp scopes(tokens, fallback) do
    case tokens["scope"] || tokens["granted_scopes"] do
      scopes when is_list(scopes) -> scopes
      scopes when is_binary(scopes) -> String.split(scopes, ~r/[ ,]+/, trim: true)
      _ -> fallback
    end
  end

  defp lock(id),
    do:
      OAuthSession
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"connector_oauth_sessions", [id]})

  defp authorize_kind(actor, "app"), do: Store.admin(actor)
  defp authorize_kind(%{type: :human}, "human"), do: :ok
  defp authorize_kind(_, _), do: {:error, :user_authority_unavailable}

  defp issuer(%{public_metadata: %{"oauth_issuer" => expected}}, actual),
    do: if(expected == actual, do: :ok, else: {:error, :oauth_issuer_mismatch})

  defp issuer(_, nil), do: :ok
  defp issuer(_, _), do: {:error, :oauth_issuer_mismatch}

  defp safe_return_to("/" <> rest = path),
    do: if(String.starts_with?(rest, "/"), do: nil, else: path)

  defp safe_return_to(_), do: nil
  def callback_url, do: AnkoleWeb.Endpoint.url() <> "/oauth/connectors/callback"
end
