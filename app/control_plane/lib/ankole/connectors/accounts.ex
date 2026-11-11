defmodule Ankole.Connectors.Accounts do
  @moduledoc false
  require Ash.Query
  alias Ankole.Connectors.{ConnectedAccount, Credentials, Store, Trigger, Triggers}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo

  def get_by_id(nil), do: {:ok, nil}
  def get_by_id(id), do: ConnectedAccount |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one()

  def cloud_account_referenced?(id) do
    ConnectedAccount
    |> Ash.Query.filter(upstream_connection_id == ^id and status == "active")
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read!()
    |> Enum.any?()
  end

  def summaries(ids) do
    ConnectedAccount
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :owner_principal_uid, :status])
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.id, &1})
  end

  def owned_ids(uid), do: uid |> owned_summaries() |> Map.keys()

  def owned_summaries(uid) do
    ConnectedAccount
    |> Ash.Query.filter(owner_principal_uid == ^uid)
    |> Ash.Query.select([:id, :owner_principal_uid, :status])
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.id, &1})
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

  def get_account(nil, _subject_kind, _account_key), do: {:ok, nil}

  def get_account(auth_config_id, subject_kind, account_key) do
    ConnectedAccount
    |> Ash.Query.filter(
      auth_config_id == ^auth_config_id and subject_kind == ^to_string(subject_kind) and
        account_key == ^account_key
    )
    |> Ankole.Ash.read_one()
  end

  def application_account(config, key \\ nil)
  def application_account(%{id: nil}, _key), do: {:ok, nil}

  def application_account(config, key) do
    key = key || config.public_metadata["installation_id"]

    accounts =
      ConnectedAccount
      |> Ash.Query.filter(
        auth_config_id == ^config.id and subject_kind == "app" and status in ["active", "expired"]
      )
      |> Ankole.Ash.read!()

    active = Enum.filter(accounts, &(&1.status == "active"))
    choices = if active == [], do: accounts, else: active

    case {key, choices} do
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

  def list_accounts(actor, scope \\ "mine") do
    with :ok <- Store.member(actor) do
      query =
        case scope do
          "mine" ->
            Ash.Query.filter(
              ConnectedAccount,
              subject_kind == "human" and owner_principal_uid == ^actor.uid
            )

          "team" ->
            Ash.Query.filter(ConnectedAccount, subject_kind == "app")
        end

      {:ok, query |> Ankole.Ash.read!() |> Enum.map(&public/1)}
    end
  end

  def connect_credentials(actor, attrs, kind) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with :ok <- Store.member(actor),
         :ok <- authorize_credentials(actor, kind),
         {:ok, config} <- Store.get_auth_config(attrs["connection"]),
         {:ok, declaration} <-
           Ankole.Plugins.Registry.fetch_adapter("connectors.connector", config.plugin_id),
         true <- kind == "app" or Map.get(declaration, :personal_credentials, false),
         true <- function_exported?(declaration.module, :validate_credentials, 2),
         {:ok, tokens} <-
           declaration.module.validate_credentials(config, attrs["credentials"] || %{}),
         {:ok, config} <- Store.materialize(config, actor.uid) do
      metadata = %{
        external_subject_id: tokens["external_subject_id"],
        public_metadata: tokens["public_metadata"] || %{},
        granted_scopes: tokens["granted_scopes"] || []
      }

      if kind == "human" do
        put_human_tokens(config.id, actor.uid, tokens, metadata)
      else
        put_app_tokens(actor, config.id, tokens, metadata)
      end
    else
      false -> {:error, :credential_binding_not_supported}
      error -> error
    end
  end

  defp put_app_tokens(actor, auth_config_id, tokens, metadata) do
    Ankole.Connectors.AuthWaits.with_flush(fn ->
      Repo.transact_top_level(
        fn ->
          with :ok <- Store.admin(actor),
               %{status: "active"} = locked <- Store.lock(auth_config_id),
               do:
                 put_tokens_in_tx(locked, "app", tokens["external_subject_id"], tokens, metadata)
        end,
        after_commit: fn _ -> Ankole.Connectors.AuthWaits.publish_flushed() end
      )
    end)
  end

  defp authorize_credentials(%{type: :human}, "human"), do: :ok
  defp authorize_credentials(actor, "app"), do: Store.admin(actor)
  defp authorize_credentials(_, _), do: {:error, :human_authority_required}

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
      Ankole.Connectors.AuthWaits.with_flush(fn ->
        Repo.transact_top_level(
          fn ->
            put_human_tokens_in_tx(auth_config_id, human_uid, tokens, metadata)
          end,
          after_commit: fn _ -> Ankole.Connectors.AuthWaits.publish_flushed() end
        )
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

    with {:ok, sealed} <- seal_tokens(tokens, id) do
      attrs =
        Map.merge(
          %{
            auth_config_id: config.id,
            plugin_id: config.plugin_id,
            subject_kind: kind,
            account_key: key,
            sealed_credentials: sealed,
            upstream_connection_id: tokens["upstream_connection_id"],
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

      result =
        if existing,
          do: Ankole.Ash.update(existing, :update, attrs),
          else: Ankole.Ash.create(ConnectedAccount, :create, Map.put(attrs, :id, id))

      with {:ok, account} <- result, :ok <- enqueue_claim(account, existing) do
        if existing && is_nil(account.upstream_connection_id),
          do: Triggers.reauthorize_account_in_tx(account.id)

        :ok = Ankole.Connectors.AuthWaits.resolve_for_account_in_tx(config, account)

        {:ok, account}
      end
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

  def revoke(account) do
    with {:ok, updated} <-
           Ankole.Ash.update(account, :update, %{
             status: "revoked",
             credentials_version: account.credentials_version + 1,
             refresh_lease_id: nil,
             refreshing_until: nil
           }),
         :ok <- enqueue_revoke(account) do
      Trigger
      |> Ash.Query.filter(connected_account_id == ^account.id)
      |> Ankole.Ash.read!()
      |> Enum.each(fn trigger ->
        {:ok, _} =
          Oban.insert(Ankole.Connectors.Jobs.ReconcileTrigger.new(%{"trigger_id" => trigger.id}))
      end)

      {:ok, updated}
    end
  end

  defp seal_tokens(%{"upstream_connection_id" => id}, _account_id) when is_binary(id),
    do: {:ok, nil}

  defp seal_tokens(tokens, id), do: Credentials.seal(tokens, "connector_connected_account", id)

  defp enqueue_claim(%{upstream_connection_id: nil}, _previous), do: :ok

  defp enqueue_claim(account, previous) do
    enqueue_cloud(%{
      "operation" => "claim",
      "local_account_id" => account.id,
      "upstream_connection_id" => account.upstream_connection_id,
      "previous_upstream_connection_id" => if(previous, do: previous.upstream_connection_id)
    })
  end

  defp enqueue_revoke(%{upstream_connection_id: nil}), do: :ok

  defp enqueue_revoke(account),
    do:
      enqueue_cloud(%{
        "operation" => "revoke",
        "upstream_connection_id" => account.upstream_connection_id
      })

  defp enqueue_cloud(args) do
    with {:ok, _} <- Oban.insert(Ankole.Connectors.Jobs.CloudAccount.new(args)), do: :ok
  end

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
        Ankole.Attrs.parse_datetime(value)

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
