defmodule Ankole.OIDC do
  @moduledoc """
  Owns OIDC clients, their group and model policy, and client-origin projection.

  Console API writes run as generic actions on `Ankole.OIDC.Client`, and
  multi-step internal writes run in `Ankole.Repo.transact_top_level/1`.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  require Ash.Query

  alias Ankole.SecretKeyBase
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AuthZ
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.AuthorizationRequest
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.ClientGroup
  alias Ankole.OIDC.Validations.ClientPolicy
  alias Ankole.OIDC.LogoutRequest
  alias Ankole.OIDC.Session
  alias Ankole.OIDC.RefreshToken
  alias Ankole.Repo

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/oidc-clients", Client do
        route(:get, "/login-sources", :login_sources, name: "list_oidc_login_sources")

        route(:post, "/:id/secret-rotations", :console_rotate_secret,
          name: "rotate_oidc_client_secret"
        )

        index(:console_list, name: "list_oidc_clients", derive_sort?: false)
        route(:post, "/", :console_create, name: "create_oidc_client")
        get(:read, name: "get_oidc_client")
        patch(:console_update, name: "update_oidc_client")
        delete(:console_delete, name: "delete_oidc_client")
      end

      base_route "/oidc-clients/:client_id/logout-deliveries", Ankole.OIDC.LogoutDelivery do
        index(:console_list, name: "list_oidc_logout_deliveries", derive_sort?: false)
        route(:post, "/:id/retries", :console_retry, name: "retry_oidc_logout_delivery")
      end
    end
  end

  defdelegate actor_for_session(id, principal, ip), to: Ankole.OIDC.Sessions

  resources do
    resource(Ankole.OIDC.Client)
    resource(Ankole.OIDC.ClientGroup)
    resource(Ankole.OIDC.SigningKeyRecord)
    resource(Ankole.OIDC.AuthorizationCode)
    resource(Ankole.OIDC.AuthorizationRequest)
    resource(Ankole.OIDC.RefreshToken)
    resource(Ankole.OIDC.RefreshTokenFamily)
    resource(Ankole.OIDC.Session)
    resource(Ankole.OIDC.LogoutRequest)
    resource(Ankole.OIDC.LogoutDelivery)
  end

  defdelegate attesto_config(), to: Ankole.OIDC.Config, as: :get

  @ai_gateway_scope "ai_gateway.write"

  @type client_result :: {:ok, Client.t()} | {:error, term()}

  @doc "Lists all OIDC clients in creation order."
  @spec list_clients() :: [map()]
  def list_clients do
    Client
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(&projection/1)
  end

  @doc "Loads one client, including disabled clients."
  @spec get_client(String.t()) :: client_result()
  def get_client(id) do
    with {:ok, id} <- cast_uuid(id) do
      case find_client(id, false) do
        %Client{} = client -> {:ok, client}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "Loads one active client."
  @spec get_active_client(String.t()) :: client_result()
  def get_active_client(id) do
    with {:ok, id} <- cast_uuid(id) do
      case find_client(id, true) do
        %Client{} = client -> {:ok, client}
        nil -> {:error, :not_found}
      end
    end
  end

  def discovery_metadata do
    issuer = Ankole.OIDC.Config.issuer()

    metadata =
      Attesto.OpenIDDiscovery.metadata(attesto_config(),
        authorization_endpoint: issuer <> "/oauth/authorize",
        userinfo_endpoint: issuer <> "/oauth/userinfo",
        introspection_endpoint: issuer <> "/oauth/introspect",
        introspection_endpoint_auth_methods_supported: ["client_secret_basic"],
        end_session_endpoint: issuer <> "/oauth/logout",
        jwks_uri: issuer <> "/.well-known/jwks.json",
        backchannel_logout_supported: true,
        backchannel_logout_session_supported: true,
        response_types_supported: ["code"],
        response_modes_supported: ["query"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        token_endpoint_auth_methods_supported: ["none", "client_secret_basic"],
        scopes_supported: Client.supported_scopes(),
        claims_supported: ~w(sub name preferred_username picture email auth_time sid)
      )

    # Attesto always advertises DPoP. This server does not accept DPoP requests.
    Map.delete(metadata, "dpop_signing_alg_values_supported")
  end

  def authorization_request(params) do
    protocol =
      if is_list(params["prompt"]),
        do: Map.put(params, "prompt", Enum.join(params["prompt"], " ")),
        else: params

    with {:ok, client} <- Ankole.OIDC.ClientAuthentication.put_client_tenant(params["client_id"]),
         {:ok, req} <-
           protocol_request(protocol, client.redirect_uris),
         :ok <- authorization_policy(req, protocol),
         true <- req.openid? and MapSet.subset?(MapSet.new(req.scope), MapSet.new(client.scopes)) do
      normalized =
        params
        |> Map.merge(%{
          "prompt" => req.prompt,
          "max_age" => req.max_age,
          "auth_time_essential?" => auth_time_essential?(req.claims),
          "scope" => Enum.join(req.scope, " ")
        })

      {:ok, client, normalized}
    else
      {:error, :not_found} -> {:error, {:direct, :invalid_client}}
      {:error, _, _} = error -> error
      {:error, _} = error -> error
      false -> {:error, "invalid_scope", "Client scope or response mode is not supported"}
    end
  end

  defp protocol_request(params, redirects) do
    case Attesto.AuthorizationRequest.validate(params, registered_redirect_uris: redirects) do
      {:error, {:redirect, error}} when is_map_key(params, "request") ->
        {:error,
         {:redirect,
          %{
            error
            | error: "request_not_supported",
              error_description: "request object is not supported"
          }}}

      {:ok, _} when is_map_key(params, "request") ->
        {:error, "request_not_supported", "request object is not supported"}

      result ->
        result
    end
  end

  defp auth_time_essential?(%{"id_token" => %{"auth_time" => %{"essential" => true}}}), do: true
  defp auth_time_essential?(_), do: false

  defp authorization_policy(req, params) do
    valid? =
      req.response_mode in [nil, "query"] and is_nil(req.dpop_jkt) and
        req.resource == [] and req.authorization_details == [] and
        length(req.prompt) == length(Enum.uniq(req.prompt)) and
        (is_nil(req.max_age) or req.max_age <= 2_147_483_647) and
        Enum.all?(
          [params["state"], params["nonce"], params["prompt"]],
          &(is_nil(&1) or is_binary(&1))
        )

    if valid?,
      do: :ok,
      else: {:error, "invalid_request", "authorization request is not supported"}
  end

  defp find_client(id, active?) do
    query = Ash.Query.filter(client_query(), id == ^id)
    query = if active?, do: Ash.Query.filter(query, enabled == true), else: query
    Ankole.Ash.read_one!(query)
  end

  # A caller that selected all tenants reads the clients of every tenant.
  defp client_query do
    action = if Repo.across_tenants?(), do: :lookup_across_tenants, else: :read
    Ash.Query.for_read(Client, action)
  end

  @doc "Creates a client and returns its one-time secret when confidential."
  @spec create_client(map()) ::
          {:ok, %{client: map(), client_secret: String.t() | nil}} | {:error, term()}
  def create_client(attrs) when is_map(attrs) do
    with {:ok, %{attrs: attrs, group_ids: group_ids}, secret} <- prepare_create(attrs),
         {:ok, client} <-
           Repo.transact_top_level(fn -> create_client_in_tx(attrs, group_ids) end) do
      {:ok, %{client: projection(client), client_secret: secret}}
    end
  end

  def create_client(_attrs), do: {:error, :invalid_request_body}

  @doc false
  def console_create_in_tx(attrs) do
    with {:ok, %{attrs: attrs, group_ids: group_ids}, secret} <- prepare_create(attrs),
         {:ok, client} <- create_client_in_tx(attrs, group_ids) do
      {:ok, %{oidc_client: load_console_fields(client), client_secret: secret}}
    end
  end

  defp prepare_create(attrs) do
    id = Ankole.Ecto.UUIDv7.autogenerate()
    client_type = Ankole.Attrs.get(attrs, :type) || Ankole.Attrs.get(attrs, :client_type)
    secret = if client_type in [:confidential, "confidential"], do: opaque_token(), else: nil

    with {:ok, secret_ciphertext} <- maybe_seal_secret(secret, id),
         normalized <- normalize_write_attrs(attrs, secret_ciphertext),
         {:ok, normalized} <- normalize_model_aliases(normalized),
         {:ok, group_ids} <- group_ids(normalized) do
      {:ok, %{attrs: Map.put(normalized, :id, id), group_ids: group_ids}, secret}
    end
  end

  @doc false
  def create_client_in_tx(attrs, group_ids) do
    with :ok <- validate_group_ids(group_ids, attrs),
         :ok <- validate_identity_provider_ids(attrs),
         {:ok, client} <-
           Ankole.Ash.create(Client, :create_in_tx, Map.drop(attrs, [:allowed_group_ids])),
         :ok <- replace_group_links(client.id, group_ids) do
      {:ok, client}
    end
  end

  @doc "Updates a client without changing its public or confidential type."
  @spec update_client(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_client(id, attrs) when is_map(attrs) do
    with {:ok, id} <- cast_uuid(id),
         {:ok, updated} <-
           Repo.transact_top_level(fn -> update_client_in_tx(id, attrs) end) do
      {:ok, projection(updated)}
    end
  end

  def update_client(_id, _attrs), do: {:error, :invalid_request_body}

  @doc false
  def update_client_in_tx(id, attrs) do
    with %Client{} = client <- lock_client(id),
         :ok <- ensure_unchanged_type(client, attrs),
         normalized <- normalize_write_attrs(attrs, nil) |> Map.delete(:secret_ciphertext),
         normalized <- preserve_missing_write_fields(client, normalized),
         {:ok, normalized} <- normalize_model_aliases(normalized),
         {:ok, group_ids} <- group_ids(normalized),
         :ok <- validate_group_ids(group_ids, normalized),
         :ok <- validate_identity_provider_ids(normalized),
         {:ok, updated} <-
           Ankole.Ash.update(
             client,
             :configure_in_tx,
             Map.drop(normalized, [:allowed_group_ids, :client_type])
           ),
         :ok <- replace_group_links(updated.id, group_ids) do
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def console_update_in_tx(%{id: id} = args) do
    case update_client_in_tx(id, Map.delete(args, :id)) do
      {:ok, client} -> {:ok, load_console_fields(client)}
      error -> Ankole.Errors.not_found(error, [:not_found], Client)
    end
  end

  @doc false
  # The result keeps the allowed groups that the client had before the delete.
  def console_delete_in_tx(id) do
    with {:ok, client} <- get_client(id),
         client = load_console_fields(client),
         {:ok, _deleted} <- Ankole.Ash.destroy(client, :delete_in_tx) do
      {:ok, client}
    else
      error -> Ankole.Errors.not_found(error, [:not_found], Client)
    end
  end

  defp load_console_fields(client),
    do: Ankole.Ash.load!(client, [:allowed_group_ids])

  @doc "Deletes a client and all of its OAuth credentials, but no Principal data."
  @spec delete_client(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_client(id) do
    with {:ok, client} <- get_client(id),
         {:ok, deleted} <- Ankole.Ash.destroy(client, :delete_in_tx) do
      {:ok, projection(deleted)}
    end
  end

  @doc "Replaces a confidential client secret and returns it once."
  @spec rotate_secret(String.t()) ::
          {:ok, %{client: map(), client_secret: String.t()}} | {:error, term()}
  def rotate_secret(id) do
    with {:ok, %Client{client_type: :confidential} = client} <- get_client(id),
         secret <- opaque_token(),
         {:ok, ciphertext} <- seal(secret, "client_secret", client.id),
         {:ok, updated} <-
           Ankole.Ash.update(client, :rotate_secret_in_tx, %{secret_ciphertext: ciphertext}) do
      {:ok, %{client: projection(updated), client_secret: secret}}
    else
      {:ok, %Client{client_type: :public}} -> {:error, :public_client}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Decrypts a confidential client secret only for protocol authentication."
  @spec client_secret(Client.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def client_secret(%Client{client_type: :public}), do: {:ok, nil}

  def client_secret(%Client{id: id, secret_ciphertext: ciphertext}) when is_binary(ciphertext) do
    SecretKeyBase.unseal(ciphertext, "oidc", ["client_secret", id])
  end

  def client_secret(%Client{}), do: {:error, :missing_client_secret}

  @doc "Returns whether an Origin belongs to one active client's HTTP redirect URIs."
  @spec origin_allowed?(Client.t() | String.t(), String.t()) :: boolean()
  def origin_allowed?(%Client{} = client, origin) when is_binary(origin) do
    origin in redirect_origins(client)
  end

  def origin_allowed?(client_id, origin) when is_binary(client_id) and is_binary(origin) do
    case get_active_client(client_id) do
      {:ok, client} -> origin_allowed?(client, origin)
      {:error, _reason} -> false
    end
  end

  def origin_allowed?(_client, _origin), do: false

  @doc "Lists every HTTP origin currently registered by an active client."
  @spec active_origins() :: [String.t()]
  def active_origins do
    client_query()
    |> Ash.Query.filter(enabled == true)
    |> Ash.Query.select([:redirect_uris])
    |> Ankole.Ash.read!()
    |> Enum.flat_map(& &1.redirect_uris)
    |> Enum.map(&ClientPolicy.redirect_origin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Lists one client's registered HTTP origins.
  @spec redirect_origins(Client.t()) :: [String.t()]
  defp redirect_origins(%Client{redirect_uris: redirect_uris}) do
    redirect_uris
    |> Enum.map(&ClientPolicy.redirect_origin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Returns one active client's allowed group ids."
  @spec allowed_group_ids(String.t()) :: [String.t()]
  def allowed_group_ids(client_id) do
    ClientGroup
    |> Ash.Query.filter(client_id == ^client_id)
    |> Ash.Query.sort(group_id: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.group_id)
  end

  @doc "Checks tenant admission, the active Client, group membership, and the optional model policy. Callers verify the token or session, the Human, and the scope."
  @spec authorize_ai_gateway(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{client: Client.t(), model_binding: map() | nil}} | {:error, term()}
  def authorize_ai_gateway(client_id, principal_uid, model_selector \\ nil) do
    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         {:ok, %Client{} = client} <- get_active_client(client_id),
         :ok <- authorize_group(client.id, principal_uid),
         {:ok, model_binding} <- authorize_model(client, model_selector) do
      {:ok, %{client: client, model_binding: model_binding}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes the tenant's expired credentials and eligible OIDC session state."
  @spec cleanup_expired_credentials(DateTime.t()) :: %{atom() => non_neg_integer()}
  def cleanup_expired_credentials(now \\ DateTime.utc_now(:microsecond)) do
    :ok = Ankole.OIDC.RefreshStore.redact_expired_successors(now)

    authorization_codes =
      AuthorizationCode
      |> Ash.Query.filter(
        expires_at <= ^now and
          (is_nil(replay_retain_until) or replay_retain_until <= ^now)
      )
      |> expire_records()

    refresh_tokens =
      RefreshToken
      |> Ash.Query.filter(
        expires_at <= ^now and
          (is_nil(successor_retry_until) or successor_retry_until < ^now)
      )
      |> expire_records(:remove_in_tx)

    authorization_requests =
      AuthorizationRequest |> Ash.Query.filter(expires_at <= ^now) |> expire_records()

    logout_requests =
      LogoutRequest |> Ash.Query.filter(expires_at <= ^now) |> expire_records()

    recent_cutoff = DateTime.add(now, -24 * 60 * 60)

    oidc_sessions =
      Session
      |> Ash.Query.filter(expires_at <= ^now and (is_nil(ended_at) or ended_at < ^recent_cutoff))
      |> Ash.Query.filter(
        fragment(
          "NOT EXISTS (SELECT 1 FROM oidc_authorization_codes AS c WHERE c.tenant_id = ? AND c.session_id = ?) AND NOT EXISTS (SELECT 1 FROM oidc_refresh_tokens AS t WHERE t.tenant_id = ? AND t.session_id = ?) AND NOT EXISTS (SELECT 1 FROM oidc_logout_deliveries AS d WHERE d.tenant_id = ? AND d.session_id = ? AND d.status <> 'delivered')",
          tenant_id,
          id,
          tenant_id,
          id,
          tenant_id,
          id
        )
      )
      |> expire_records()

    %{
      authorization_codes: authorization_codes,
      authorization_requests: authorization_requests,
      refresh_tokens: refresh_tokens,
      logout_requests: logout_requests,
      oidc_sessions: oidc_sessions
    }
  end

  defp expire_records(query, action \\ :expire_in_tx) do
    query
    |> Ash.Query.select(Ash.Resource.Info.primary_key(query.resource))
    |> Ankole.Ash.destroy_where(action)
    |> case do
      {:ok, records} -> length(records)
      {:error, error} -> raise error
    end
  end

  @doc "Projects one client without its encrypted secret."
  @spec projection(Client.t()) :: map()
  def projection(%Client{} = client) do
    %{
      id: client.id,
      name: client.name,
      enabled: client.enabled,
      type: Atom.to_string(client.client_type),
      redirect_uris: client.redirect_uris,
      scopes: client.scopes,
      allowed_group_ids: allowed_group_ids(client.id),
      allowed_models: client.model_aliases,
      allowed_identity_provider_ids: client.allowed_identity_provider_ids,
      backchannel_logout_uri: client.backchannel_logout_uri,
      backchannel_logout_session_required: client.backchannel_logout_session_required,
      post_logout_redirect_uris: client.post_logout_redirect_uris,
      allow_insecure_local_logout: client.allow_insecure_local_logout,
      inserted_at: DateTime.to_iso8601(client.inserted_at),
      updated_at: DateTime.to_iso8601(client.updated_at)
    }
  end

  defp normalize_write_attrs(attrs, secret_ciphertext) do
    scopes = Ankole.Attrs.get(attrs, :scopes)

    normalized = %{
      name: Ankole.Attrs.get(attrs, :name),
      enabled: Ankole.Attrs.get(attrs, :enabled),
      client_type: Ankole.Attrs.get(attrs, :type) || Ankole.Attrs.get(attrs, :client_type),
      secret_ciphertext: secret_ciphertext,
      redirect_uris: Ankole.Attrs.get(attrs, :redirect_uris),
      scopes: scopes,
      model_aliases:
        Ankole.Attrs.get(attrs, :allowed_models) || Ankole.Attrs.get(attrs, :model_aliases),
      allowed_group_ids: Ankole.Attrs.get(attrs, :allowed_group_ids)
    }

    normalized =
      Enum.reduce(
        [
          :allowed_identity_provider_ids,
          :backchannel_logout_uri,
          :backchannel_logout_session_required,
          :post_logout_redirect_uris,
          :allow_insecure_local_logout
        ],
        normalized,
        fn key, acc ->
          if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)),
            do: Map.put(acc, key, Ankole.Attrs.get(attrs, key)),
            else: acc
        end
      )

    if is_list(scopes) and @ai_gateway_scope not in scopes do
      %{normalized | model_aliases: %{}, allowed_group_ids: []}
    else
      normalized
    end
  end

  defp preserve_missing_write_fields(client, attrs) do
    defaults = %{
      name: client.name,
      enabled: client.enabled,
      client_type: client.client_type,
      redirect_uris: client.redirect_uris,
      scopes: client.scopes,
      model_aliases: client.model_aliases,
      allowed_group_ids: allowed_group_ids(client.id)
    }

    Map.new(attrs, fn {key, value} ->
      {key,
       if(is_nil(value) and Map.has_key?(defaults, key),
         do: Map.fetch!(defaults, key),
         else: value
       )}
    end)
  end

  defp validate_identity_provider_ids(%{allowed_identity_provider_ids: ids}) when is_list(ids) do
    Enum.reduce_while(ids, :ok, fn
      id, :ok when is_binary(id) ->
        case if(Ankole.IdentityProviders.SiteSources.registered?(id),
               do: {:ok, id},
               else: Ankole.IdentityProviders.fetch_configured_provider(id)
             ) do
          {:ok, _} -> {:cont, :ok}
          _ -> {:halt, {:error, :unknown_identity_provider}}
        end

      _, :ok ->
        {:halt, {:error, :invalid_identity_provider_ids}}
    end)
  end

  defp validate_identity_provider_ids(%{allowed_identity_provider_ids: _}),
    do: {:error, :invalid_identity_provider_ids}

  defp validate_identity_provider_ids(_), do: :ok

  defp normalize_model_aliases(%{model_aliases: aliases} = attrs) when is_map(aliases) do
    aliases
    |> Enum.reduce_while({:ok, %{}}, fn {name, binding}, {:ok, normalized} ->
      name = if is_atom(name), do: Atom.to_string(name), else: name

      case ModelProfiles.normalize_custom_model_profile(name, binding) do
        {:ok, profile} ->
          if Map.has_key?(normalized, String.trim(name)) do
            {:halt, {:error, {:invalid_model_alias, name, :duplicate}}}
          else
            {:cont, {:ok, Map.put(normalized, String.trim(name), profile)}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_model_alias, name, reason}}}
      end
    end)
    |> case do
      {:ok, aliases} -> {:ok, %{attrs | model_aliases: aliases}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_model_aliases(%{model_aliases: _value}),
    do: {:error, {:invalid_model_aliases, :not_an_object}}

  defp ensure_unchanged_type(%Client{client_type: type}, attrs) do
    case Ankole.Attrs.get(attrs, :type) || Ankole.Attrs.get(attrs, :client_type) do
      nil ->
        :ok

      ^type ->
        :ok

      value when is_binary(value) ->
        if value == Atom.to_string(type), do: :ok, else: {:error, :client_type_immutable}

      _different ->
        {:error, :client_type_immutable}
    end
  end

  defp group_ids(attrs) do
    case attrs.allowed_group_ids do
      ids when is_list(ids) ->
        ids =
          ids
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if length(ids) == length(Enum.uniq(attrs.allowed_group_ids)) do
          {:ok, ids}
        else
          {:error, :invalid_allowed_group_ids}
        end

      _value ->
        {:error, :invalid_allowed_group_ids}
    end
  end

  defp validate_group_ids([], %{scopes: scopes}) when is_list(scopes) do
    if @ai_gateway_scope in scopes, do: {:error, :allowed_group_required}, else: :ok
  end

  # AuthZ owns the groups.
  defp validate_group_ids(group_ids, _attrs) do
    case AuthZ.list_groups(query: [filter: [id: [in: group_ids]], select: [:id]]) do
      {:ok, groups} ->
        found = MapSet.new(groups, & &1.id)
        if found == MapSet.new(group_ids), do: :ok, else: {:error, :unknown_group}

      {:error, _invalid_id} ->
        {:error, :unknown_group}
    end
  end

  defp replace_group_links(client_id, group_ids) do
    with {:ok, _unlinked} <-
           ClientGroup
           |> Ash.Query.filter(client_id == ^client_id)
           |> Ankole.Ash.destroy_where(:unlink_in_tx) do
      Enum.reduce_while(group_ids, :ok, fn group_id, :ok ->
        case Ankole.Ash.create(ClientGroup, :link_in_tx, %{
               client_id: client_id,
               group_id: group_id
             }) do
          {:ok, _link} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp authorize_group(client_id, principal_uid) do
    allowed = MapSet.new(allowed_group_ids(client_id))

    with false <- MapSet.size(allowed) == 0,
         {:ok, current_groups} <- AuthZ.list_current_groups_for_principal(principal_uid),
         true <- Enum.any?(current_groups, &MapSet.member?(allowed, &1.id)) do
      :ok
    else
      true -> {:error, :group_not_allowed}
      {:error, reason} -> {:error, reason}
      false -> {:error, :group_not_allowed}
    end
  end

  defp authorize_model(_client, nil), do: {:ok, nil}

  defp authorize_model(%Client{model_aliases: aliases}, selector) when is_binary(selector) do
    case Map.fetch(aliases, selector) do
      {:ok, binding} -> {:ok, Map.put(binding, "profile", selector)}
      :error -> {:error, :model_not_allowed}
    end
  end

  defp authorize_model(_client, _selector), do: {:error, :model_not_allowed}

  defp lock_client(id) do
    Client
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp maybe_seal_secret(nil, _id), do: {:ok, nil}
  defp maybe_seal_secret(secret, id), do: seal(secret, "client_secret", id)

  @doc false
  def seal(plaintext, kind, id), do: SecretKeyBase.seal(plaintext, "oidc", [kind, id])

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, cast} -> {:ok, cast}
      :error -> {:error, :not_found}
    end
  end

  defp opaque_token do
    Attesto.Secret.generate()
  end
end
