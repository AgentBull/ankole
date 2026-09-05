defmodule Ankole.OIDC do
  @moduledoc """
  Owns OIDC clients, their group and model policy, and client-origin projection.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Group
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.ClientGroup
  alias Ankole.OIDC.Crypto
  alias Ankole.OIDC.RefreshToken
  alias Ankole.Principals
  alias Ankole.Repo

  @ai_gateway_scope "ai_gateway.write"

  @type client_result :: {:ok, Client.t()} | {:error, term()}

  @doc "Lists all OIDC clients in creation order."
  @spec list_clients() :: [map()]
  def list_clients do
    Client
    |> order_by([client], asc: client.inserted_at)
    |> Repo.all()
    |> Enum.map(&projection/1)
  end

  @doc "Loads one client, including disabled clients."
  @spec get_client(String.t()) :: client_result()
  def get_client(id) do
    with {:ok, id} <- cast_uuid(id) do
      case Repo.get(Client, id) do
        %Client{} = client -> {:ok, client}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "Loads one active client."
  @spec get_active_client(String.t()) :: client_result()
  def get_active_client(id) do
    with {:ok, id} <- cast_uuid(id) do
      case Repo.get_by(Client, id: id, enabled: true) do
        %Client{} = client -> {:ok, client}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "Creates a client and returns its one-time secret when confidential."
  @spec create_client(map()) ::
          {:ok, %{client: map(), client_secret: String.t() | nil}} | {:error, term()}
  def create_client(attrs) when is_map(attrs) do
    id = Ankole.Ecto.UUIDv7.autogenerate()
    client_type = fetch(attrs, :type) || fetch(attrs, :client_type)
    secret = if client_type in [:confidential, "confidential"], do: opaque_token(), else: nil

    with {:ok, secret_ciphertext} <- maybe_seal_secret(secret, id),
         normalized <- normalize_write_attrs(attrs, secret_ciphertext),
         {:ok, normalized} <- normalize_model_aliases(normalized),
         {:ok, group_ids} <- group_ids(normalized),
         {:ok, client} <-
           Repo.transact(fn repo ->
             with :ok <- validate_group_ids(repo, group_ids, normalized),
                  {:ok, client} <-
                    %Client{id: id}
                    |> Client.changeset(Map.drop(normalized, [:allowed_group_ids]))
                    |> repo.insert(),
                  :ok <- replace_group_links(repo, client.id, group_ids) do
               {:ok, client}
             end
           end) do
      {:ok, %{client: projection(client), client_secret: secret}}
    end
  end

  def create_client(_attrs), do: {:error, :invalid_request_body}

  @doc "Updates a client without changing its public or confidential type."
  @spec update_client(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_client(id, attrs) when is_map(attrs) do
    with {:ok, id} <- cast_uuid(id),
         {:ok, updated} <-
           Repo.transact(fn repo ->
             with %Client{} = client <- lock_client(repo, id),
                  :ok <- ensure_unchanged_type(client, attrs),
                  normalized <-
                    normalize_write_attrs(attrs, nil) |> Map.delete(:secret_ciphertext),
                  normalized <- preserve_missing_write_fields(client, normalized),
                  {:ok, normalized} <- normalize_model_aliases(normalized),
                  {:ok, group_ids} <- group_ids(normalized),
                  :ok <- validate_group_ids(repo, group_ids, normalized),
                  {:ok, updated} <-
                    client
                    |> Client.changeset(Map.drop(normalized, [:allowed_group_ids]))
                    |> repo.update(),
                  :ok <- replace_group_links(repo, updated.id, group_ids) do
               {:ok, updated}
             else
               nil -> {:error, :not_found}
               {:error, reason} -> {:error, reason}
             end
           end) do
      {:ok, projection(updated)}
    end
  end

  def update_client(_id, _attrs), do: {:error, :invalid_request_body}

  @doc "Deletes a client and all of its OAuth credentials, but no Principal data."
  @spec delete_client(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_client(id) do
    with {:ok, client} <- get_client(id),
         {:ok, deleted} <- Repo.delete(client) do
      {:ok, projection(deleted)}
    end
  end

  @doc "Replaces a confidential client secret and returns it once."
  @spec rotate_secret(String.t()) ::
          {:ok, %{client: map(), client_secret: String.t()}} | {:error, term()}
  def rotate_secret(id) do
    with {:ok, %Client{client_type: :confidential} = client} <- get_client(id),
         secret <- opaque_token(),
         {:ok, ciphertext} <- Crypto.seal(secret, "client_secret", client.id),
         {:ok, updated} <-
           client
           |> Client.changeset(%{secret_ciphertext: ciphertext})
           |> Repo.update() do
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
    Crypto.unseal(ciphertext, "client_secret", id)
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
    Client
    |> where([client], client.enabled == true)
    |> select([client], client.redirect_uris)
    |> Repo.all()
    |> List.flatten()
    |> Enum.map(&Client.redirect_origin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Lists one client's registered HTTP origins."
  @spec redirect_origins(Client.t()) :: [String.t()]
  def redirect_origins(%Client{redirect_uris: redirect_uris}) do
    redirect_uris
    |> Enum.map(&Client.redirect_origin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Returns one active client's allowed group ids."
  @spec allowed_group_ids(String.t()) :: [String.t()]
  def allowed_group_ids(client_id) do
    ClientGroup
    |> where([link], link.client_id == ^client_id)
    |> order_by([link], asc: link.group_id)
    |> select([link], link.group_id)
    |> Repo.all()
  end

  @doc "Checks the live Human, Client, Scope, group, and optional model policy."
  @spec authorize_ai_gateway(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{client: Client.t(), model_binding: map() | nil}} | {:error, term()}
  def authorize_ai_gateway(client_id, principal_uid, model_selector \\ nil) do
    with {:ok, %Client{} = client} <- get_active_client(client_id),
         true <- @ai_gateway_scope in client.scopes || {:error, :scope_revoked},
         {:ok, principal} <- Principals.get_principal(principal_uid),
         true <-
           (principal.type == :human and principal.status == :active) || {:error, :inactive_human},
         :ok <- authorize_group(client.id, principal.uid),
         {:ok, model_binding} <- authorize_model(client, model_selector) do
      {:ok, %{client: client, model_binding: model_binding}}
    else
      false -> {:error, :inactive_human}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes expired authorization codes and OIDC refresh tokens."
  @spec cleanup_expired_credentials(DateTime.t()) :: %{
          authorization_codes: non_neg_integer(),
          refresh_tokens: non_neg_integer()
        }
  def cleanup_expired_credentials(now \\ DateTime.utc_now(:microsecond)) do
    {authorization_codes, _rows} =
      AuthorizationCode
      |> where([code], code.expires_at <= ^now)
      |> Repo.delete_all()

    {refresh_tokens, _rows} =
      RefreshToken
      |> where([token], token.absolute_expires_at <= ^now)
      |> Repo.delete_all()

    %{authorization_codes: authorization_codes, refresh_tokens: refresh_tokens}
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
      inserted_at: DateTime.to_iso8601(client.inserted_at),
      updated_at: DateTime.to_iso8601(client.updated_at)
    }
  end

  defp normalize_write_attrs(attrs, secret_ciphertext) do
    scopes = fetch(attrs, :scopes)

    normalized = %{
      name: fetch(attrs, :name),
      enabled: fetch(attrs, :enabled),
      client_type: fetch(attrs, :type) || fetch(attrs, :client_type),
      secret_ciphertext: secret_ciphertext,
      redirect_uris: fetch(attrs, :redirect_uris),
      scopes: scopes,
      model_aliases: fetch(attrs, :allowed_models) || fetch(attrs, :model_aliases),
      allowed_group_ids: fetch(attrs, :allowed_group_ids)
    }

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
      {key, if(is_nil(value), do: Map.fetch!(defaults, key), else: value)}
    end)
  end

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
    case fetch(attrs, :type) || fetch(attrs, :client_type) do
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

  defp validate_group_ids(_repo, [], %{scopes: scopes}) when is_list(scopes) do
    if @ai_gateway_scope in scopes, do: {:error, :allowed_group_required}, else: :ok
  end

  defp validate_group_ids(repo, group_ids, _attrs) do
    found =
      Group
      |> where([group], group.id in ^group_ids)
      |> select([group], group.id)
      |> repo.all()

    if MapSet.new(found) == MapSet.new(group_ids), do: :ok, else: {:error, :unknown_group}
  end

  defp replace_group_links(repo, client_id, group_ids) do
    _ = repo.delete_all(from link in ClientGroup, where: link.client_id == ^client_id)

    Enum.reduce_while(group_ids, :ok, fn group_id, :ok ->
      case %ClientGroup{}
           |> ClientGroup.changeset(%{client_id: client_id, group_id: group_id})
           |> repo.insert() do
        {:ok, _link} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp lock_client(repo, id) do
    repo.one(from client in Client, where: client.id == ^id, lock: "FOR UPDATE")
  end

  defp maybe_seal_secret(nil, _id), do: {:ok, nil}
  defp maybe_seal_secret(secret, id), do: Crypto.seal(secret, "client_secret", id)

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, cast} -> {:ok, cast}
      :error -> {:error, :not_found}
    end
  end

  defp opaque_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
