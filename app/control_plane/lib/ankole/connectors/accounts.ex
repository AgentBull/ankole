defmodule Ankole.Connectors.Accounts do
  @moduledoc false
  require Ash.Query
  alias Ankole.Connectors.{ConnectedAccount, Credentials, Store}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo

  def get_by_id(nil), do: {:ok, nil}
  def get_by_id(id), do: ConnectedAccount |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one()

  def owned_ids(uid) do
    ConnectedAccount
    |> Ash.Query.filter(owner_principal_uid == ^uid)
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
  end

  def sync_installation_in_tx(%{plugin_id: "github", auth_scheme: "github_app"} = config) do
    case config.public_metadata["installation_id"] do
      key when is_binary(key) and key != "" ->
        {:ok, existing} = get_account(config.id, "app", key)

        attrs = %{
          auth_config_id: config.id,
          plugin_id: "github",
          subject_kind: "app",
          account_key: key,
          external_subject_id: key,
          status: "active",
          public_metadata: Map.take(config.public_metadata, ["repositories"])
        }

        result =
          if existing do
            Ankole.Ash.update(lock(existing.id), :update, attrs)
          else
            Ankole.Ash.create(ConnectedAccount, :create, attrs)
          end

        case result do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end

  def sync_installation_in_tx(_config), do: :ok

  def get_account(auth_config_id, subject_kind, account_key) do
    ConnectedAccount
    |> Ash.Query.filter(
      auth_config_id == ^auth_config_id and subject_kind == ^to_string(subject_kind) and
        account_key == ^account_key
    )
    |> Ankole.Ash.read_one()
  end

  def application_account(config, key \\ nil) do
    key = key || config.public_metadata["installation_id"]

    accounts =
      ConnectedAccount
      |> Ash.Query.filter(
        auth_config_id == ^config.id and subject_kind == "app" and status == "active"
      )
      |> Ankole.Ash.read!()

    case {key, accounts} do
      {nil, []} ->
        {:ok, nil}

      {nil, [account]} ->
        {:ok, account}

      {nil, _} ->
        {:error, :connection_account_required}

      {key, _} ->
        case Enum.find(accounts, &(&1.account_key == key)) do
          nil -> {:error, :connection_account_not_found}
          account -> {:ok, account}
        end
    end
  end

  def application_choices do
    with {:ok, accounts} <-
           ConnectedAccount
           |> Ash.Query.filter(subject_kind == "app" and status == "active")
           |> Ash.Query.select([:auth_config_id, :account_key])
           |> Ankole.Ash.read() do
      {:ok, Enum.group_by(accounts, & &1.auth_config_id, & &1.account_key)}
    end
  end

  def list_accounts(actor) do
    with :ok <- Store.member(actor) do
      query =
        if Ankole.AuthZ.pod_admin?(actor.uid),
          do: Ash.Query.new(ConnectedAccount),
          else: Ash.Query.filter(ConnectedAccount, owner_principal_uid == ^actor.uid)

      {:ok, query |> Ankole.Ash.read!() |> Enum.map(&public/1)}
    end
  end

  def disconnect_account(actor, id) do
    with :ok <- Store.member(actor) do
      Repo.transact_top_level(fn ->
        with %ConnectedAccount{} = account <- lock(id),
             true <-
               account.owner_principal_uid == actor.uid or Ankole.AuthZ.pod_admin?(actor.uid) do
          revoke(account)
        else
          nil -> {:error, :not_found}
          false -> {:error, :forbidden}
        end
      end)
    end
  end

  def put_human_tokens(auth_config_id, human_uid, tokens, metadata \\ %{}),
    do:
      Repo.transact_top_level(fn ->
        put_human_tokens_in_tx(auth_config_id, human_uid, tokens, metadata)
      end)

  def put_human_tokens_in_tx(auth_config_id, human_uid, tokens, metadata \\ %{}) do
    work = WorkAccess.from_sender(human_uid)

    with :ok <- WorkAccess.check_in_tx(work),
         %{authorization_kind: "human", human_access_version: version} <- work,
         %{status: "active"} = config <- Store.lock(auth_config_id) do
      put_tokens_in_tx(
        config,
        "human",
        human_uid,
        tokens,
        Map.merge(metadata, %{owner_principal_uid: human_uid, owner_access_version: version})
      )
    else
      nil -> {:error, :connection_required}
      {:error, _} = error -> error
      _ -> {:error, :user_authority_unavailable}
    end
  end

  def put_tokens_in_tx(config, kind, key, tokens, metadata) do
    {:ok, existing} = get_account(config.id, kind, key)
    existing = if existing, do: lock(existing.id)
    id = if existing, do: existing.id, else: Ankole.Kernel.gen_uuid_v7()

    with {:ok, sealed} <- Credentials.seal(tokens, "connector_connected_account", id) do
      attrs =
        Map.merge(
          %{
            auth_config_id: config.id,
            plugin_id: config.plugin_id,
            subject_kind: kind,
            account_key: key,
            sealed_credentials: sealed,
            credentials_version: if(existing, do: existing.credentials_version + 1, else: 1),
            status: "active",
            refresh_lease_id: nil,
            refreshing_until: nil,
            last_refresh_failure_at: nil,
            first_refresh_failure_at: nil,
            last_error: nil,
            expires_at: expiry(tokens, "expires_at", "expires_in"),
            refresh_expires_at: expiry(tokens, "refresh_expires_at", "refresh_expires_in")
          },
          Map.take(metadata, [
            :external_subject_id,
            :granted_scopes,
            :public_metadata,
            :owner_principal_uid,
            :owner_access_version
          ])
        )

      if existing,
        do: Ankole.Ash.update(existing, :update, attrs),
        else: Ankole.Ash.create(ConnectedAccount, :create, Map.put(attrs, :id, id))
    end
  end

  def revoke_human_accounts_in_tx(uid, version) do
    accounts =
      ConnectedAccount
      |> Ash.Query.filter(
        subject_kind == "human" and owner_principal_uid == ^uid and
          owner_access_version < ^version and status != "revoked"
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read!(lock_identity: {:rows, "connector_connected_accounts", :id})

    Enum.each(accounts, fn account ->
      case revoke(account) do
        {:ok, _} -> :ok
        {:error, error} -> Repo.rollback(error)
      end
    end)

    :ok
  end

  def revoke(account),
    do:
      Ankole.Ash.update(account, :update, %{
        status: "revoked",
        credentials_version: account.credentials_version + 1,
        refresh_lease_id: nil,
        refreshing_until: nil
      })

  def lock(id),
    do:
      ConnectedAccount
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"connector_connected_accounts", [id]})

  def valid?(%{subject_kind: "app", status: "active"}), do: true

  def valid?(%{subject_kind: "human", status: "active"} = account),
    do:
      WorkAccess.valid_now?(%{
        authorization_kind: "human",
        human_uid: account.owner_principal_uid,
        human_access_version: account.owner_access_version
      })

  def valid?(_), do: false

  def public(account),
    do:
      account
      |> Map.from_struct()
      |> Map.take([
        :id,
        :auth_config_id,
        :plugin_id,
        :subject_kind,
        :account_key,
        :owner_principal_uid,
        :external_subject_id,
        :granted_scopes,
        :public_metadata,
        :status,
        :expires_at,
        :refresh_expires_at,
        :last_error,
        :updated_at
      ])

  def expiry(tokens, absolute, relative) do
    case tokens[absolute] do
      %DateTime{} = time ->
        time

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, time, _} -> time
          _ -> nil
        end

      value when is_integer(value) ->
        DateTime.from_unix!(value)

      _ ->
        case tokens[relative] do
          value when is_integer(value) -> DateTime.add(DateTime.utc_now(), value, :second)
          _ -> nil
        end
    end
  end
end
