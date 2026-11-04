defmodule Ankole.Connectors.Store do
  @moduledoc false
  require Ash.Query

  alias Ankole.Connectors.{
    Accounts,
    AuthConfig,
    CloudProvider,
    ConnectedAccount,
    Credentials,
    Registry
  }

  alias Ankole.Repo

  def active_auth_configs(plugin_id),
    do:
      AuthConfig
      |> Ash.Query.filter(plugin_id == ^plugin_id and status == "active")
      |> Ankole.Ash.read()

  def list_auth_configs(actor) do
    with :ok <- member(actor), do: list_public_auth_configs()
  end

  def list_public_auth_configs do
    with {:ok, configs} <- available_configs(), do: {:ok, Enum.map(configs, &public/1)}
  end

  def get_auth_config(selector, plugin_id \\ nil)
  def get_auth_config(nil, nil), do: {:error, :connection_required}

  def get_auth_config(selector, plugin_id) do
    with {:ok, stored} <- stored_configs() do
      case select_config(stored, selector, plugin_id) do
        {:error, :connection_required} ->
          with {:ok, configs} <- add_cloud_defaults(stored),
               do: select_config(configs, selector, plugin_id)

        result ->
          result
      end
    end
  end

  defp select_config(configs, selector, plugin_id) do
    configs = if plugin_id, do: Enum.filter(configs, &(&1.plugin_id == plugin_id)), else: configs

    selected =
      if is_nil(selector) do
        active = Enum.filter(configs, &(&1.status == "active"))

        case Enum.filter(active, &(&1.mode == "local")) do
          [] -> Enum.find(active, &(&1.mode == "cloud"))
          [config] -> config
          many -> Enum.find(many, & &1.is_default)
        end
      else
        Enum.find(configs, &(&1.id == selector or &1.slug == selector))
      end

    case selected do
      %AuthConfig{status: "active"} = config -> {:ok, config}
      %AuthConfig{} -> {:error, :connection_disabled}
      nil -> {:error, :connection_required}
    end
  end

  defp stored_configs,
    do: AuthConfig |> Ash.Query.sort(plugin_id: :asc, slug: :asc) |> Ankole.Ash.read()

  defp available_configs do
    with {:ok, stored} <- stored_configs(), do: add_cloud_defaults(stored)
  end

  defp add_cloud_defaults(stored) do
    with {:ok, cloud} <- CloudProvider.available_connectors() do
      missing =
        Enum.reject(cloud, fn item ->
          Enum.any?(stored, &(&1.plugin_id == item["plugin_id"] and &1.mode == "cloud"))
        end)

      generated =
        for item <- missing, match?({:ok, _}, Registry.adapter(item["plugin_id"])) do
          %AuthConfig{
            id: nil,
            tenant_id: Repo.tenant_id!(),
            mode: "cloud",
            plugin_id: item["plugin_id"],
            slug: cloud_slug(item["plugin_id"], stored),
            display_name: item["display_name"],
            auth_scheme: item["auth_scheme"],
            status: "active",
            is_default: false,
            public_metadata: %{},
            secret_version: 1
          }
        end

      {:ok, stored ++ generated}
    end
  end

  defp cloud_slug(plugin, configs) do
    slugs = MapSet.new(configs, & &1.slug)

    Stream.concat(
      [plugin, plugin <> "-cloud"],
      Stream.iterate(2, &(&1 + 1)) |> Stream.map(&(plugin <> "-cloud-" <> to_string(&1)))
    )
    |> Enum.find(&(not MapSet.member?(slugs, &1)))
  end

  def materialize(%AuthConfig{id: nil, mode: "cloud"} = config, actor_uid) do
    Repo.transact_top_level(fn ->
      :ok = lock_default_in_tx(config.plugin_id)

      with {:ok, _current} <- get_auth_config(config.slug, config.plugin_id) do
        case AuthConfig
             |> Ash.Query.filter(plugin_id == ^config.plugin_id and mode == "cloud")
             |> Ankole.Ash.read_one() do
          {:ok, nil} ->
            # Resolve the slug again while holding the platform's configuration lock.
            {:ok, stored} = Ankole.Ash.read(AuthConfig)

            Ankole.Ash.create(AuthConfig, :create, %{
              plugin_id: config.plugin_id,
              mode: "cloud",
              slug: cloud_slug(config.plugin_id, stored),
              display_name: config.display_name,
              auth_scheme: config.auth_scheme,
              public_metadata: %{},
              created_by_uid: actor_uid
            })

          {:ok, row} ->
            {:ok, row}

          error ->
            error
        end
      end
    end)
  end

  def materialize(config, _actor_uid), do: {:ok, config}

  def get_auth_config_for_configuration(id, plugin_id \\ nil) do
    query = Ash.Query.filter(AuthConfig, id == ^id)
    query = if plugin_id, do: Ash.Query.filter(query, plugin_id == ^plugin_id), else: query

    case Ankole.Ash.read_one(query) do
      {:ok, %AuthConfig{} = config} -> {:ok, config}
      {:ok, nil} -> {:error, :connection_required}
      error -> error
    end
  end

  def create_auth_config(actor, attrs) do
    with :ok <- admin(actor),
         {:ok, attrs} <- prepare(attrs),
         do:
           Repo.transact_top_level(fn -> create_in_tx(actor.uid, attrs) end,
             after_commit: fn _ ->
               Phoenix.PubSub.broadcast(
                 Ankole.PubSub,
                 "connector_credentials",
                 {:connector_credentials_changed, Repo.tenant_id!()}
               )
             end
           )
           |> normalize_write_error()
  end

  def create_in_tx(actor_uid, attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)
    id = Ankole.Kernel.gen_uuid_v7()
    secret = attrs["secret"] || %{}

    with :ok <- validate(attrs, secret),
         :ok <- select_default_in_tx(attrs["plugin_id"], nil, attrs["is_default"] == true),
         {:ok, sealed} <- Credentials.seal(secret, "connector_auth_config", id),
         {:ok, row} <-
           Ankole.Ash.create(AuthConfig, :create, %{
             id: id,
             plugin_id: attrs["plugin_id"],
             slug: attrs["slug"],
             display_name: attrs["display_name"] || attrs["slug"],
             auth_scheme: attrs["auth_scheme"],
             status: attrs["status"] || "active",
             is_default: attrs["is_default"] || false,
             platform_application: attrs["platform_application"],
             platform_client_id: platform_client_id(attrs["plugin_id"], secret),
             public_metadata: attrs["public_metadata"] || %{},
             sealed_secret: sealed,
             created_by_uid: actor_uid
           }),
         :ok <- Accounts.sync_installation_in_tx(row) do
      {:ok, row}
    else
      error -> normalize_write_error(error)
    end
  end

  def update_auth_config(actor, id, attrs) do
    with :ok <- admin(actor),
         %AuthConfig{} = original <-
           AuthConfig |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         {:ok, changes} <- changes(original, attrs) do
      Repo.transact_top_level(
        fn ->
          with :ok <- select_default_in_tx(original.plugin_id, id, changes["is_default"] == true),
               %AuthConfig{} = row <- lock(id),
               true <- row.secret_version == original.secret_version,
               {:ok, updated} <- update_in_tx(row, changes) do
            {:ok, updated}
          else
            nil -> {:error, :not_found}
            false -> {:error, :connection_changed}
            error -> error
          end
        end,
        after_commit: fn _ ->
          Phoenix.PubSub.broadcast(
            Ankole.PubSub,
            "connector_credentials",
            {:connector_credentials_changed, Repo.tenant_id!()}
          )
        end
      )
      |> normalize_write_error()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def update_in_tx(row, changes) do
    credentials_changed? =
      Enum.any?(
        [:sealed_secret, :platform_application, :platform_client_id, :public_metadata, :status],
        fn field ->
          key = Atom.to_string(field)
          Map.has_key?(changes, key) && changes[key] != Map.fetch!(row, field)
        end
      )

    changes =
      if credentials_changed?,
        do: Map.put(changes, "secret_version", row.secret_version + 1),
        else: changes

    with {:ok, updated} <- Ankole.Ash.update(row, :update, changes),
         :ok <- if(credentials_changed?, do: invalidate_accounts(row.id), else: :ok),
         :ok <- sync_installation(updated, changes),
         do: {:ok, updated}
  end

  defp normalize_write_error(result), do: Ankole.Errors.reason(result)

  defp select_default_in_tx(_plugin, _selected_id, false), do: :ok

  defp select_default_in_tx(plugin, selected_id, true) do
    :ok = lock_default_in_tx(plugin)

    AuthConfig
    |> Ash.Query.filter(plugin_id == ^plugin)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "connector_auth_configs", :id})
    |> Enum.filter(&(&1.mode == "local" && &1.is_default && &1.id != selected_id))
    |> Enum.reduce_while(:ok, fn config, :ok ->
      case Ankole.Ash.update(config, :update, %{is_default: false}) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def lock_default_in_tx(plugin) do
    Ankole.AdvisoryLock.lock!(Repo, "connector_default:#{Repo.tenant_id!()}:#{plugin}")
    :ok
  end

  defp sync_installation(config, attrs) do
    metadata = Ankole.Attrs.get(attrs, :public_metadata) || %{}

    if Map.has_key?(metadata, "installation_id"),
      do: Accounts.sync_installation_in_tx(config),
      else: :ok
  end

  def lock(id),
    do:
      AuthConfig
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"connector_auth_configs", [id]})

  defp invalidate_accounts(id) do
    ConnectedAccount
    |> Ash.Query.filter(auth_config_id == ^id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "connector_connected_accounts", :id})
    |> Enum.each(fn account ->
      case Ankole.Ash.update(account, :update, %{
             credentials_version: account.credentials_version + 1,
             refresh_lease_id: nil,
             refreshing_until: nil
           }) do
        {:ok, _} -> :ok
        {:error, error} -> Repo.rollback(error)
      end
    end)

    :ok
  end

  defp changes(row, attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)
    changes = Map.take(attrs, ~w(display_name slug is_default public_metadata status))
    patch = Map.get(attrs, "secret", %{})

    with true <- is_map(patch),
         {:ok, previous} <- Credentials.secret(row),
         patch = credential_patch(row.plugin_id, previous, canonical_secret(patch, row.plugin_id)),
         secret = Map.merge(previous, patch),
         metadata = Map.get(changes, "public_metadata", row.public_metadata),
         {:ok, application} <-
           if(secret == previous && metadata == row.public_metadata,
             do: {:ok, row.platform_application},
             else: application_identity(row.plugin_id, Map.merge(metadata, secret))
           ),
         {:ok, credentials} <- credential_changes(row, application, previous, secret) do
      {:ok, Map.merge(changes, credentials)}
    else
      false -> {:error, :invalid_credentials}
      error -> error
    end
  end

  def credential_changes(row, application, previous, secret) do
    with :ok <- same_application(row, application, previous, secret) do
      identity = %{
        "platform_application" => application,
        "platform_client_id" => platform_client_id(row.plugin_id, secret)
      }

      if secret == previous do
        {:ok, identity}
      else
        with {:ok, sealed} <- Credentials.seal(secret, "connector_auth_config", row.id),
             do: {:ok, Map.put(identity, "sealed_secret", sealed)}
      end
    end
  end

  defp same_application(%{plugin_id: "slack"} = row, application, previous, secret) do
    client_id = platform_client_id("slack", previous)

    cond do
      is_binary(client_id) and secret["clientID"] != client_id ->
        {:error, :connection_application_change_requires_new_connection}

      row.platform_application == application ->
        :ok

      is_binary(client_id) and row.platform_application == "slack-client:" <> client_id and
          String.starts_with?(application, "slack:") ->
        :ok

      true ->
        {:error, :connection_application_change_requires_new_connection}
    end
  end

  defp same_application(%{platform_application: application}, application, _previous, _secret),
    do: :ok

  defp same_application(_, _, _, _),
    do: {:error, :connection_application_change_requires_new_connection}

  defp platform_client_id("slack", secret) do
    case secret["clientID"] do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp platform_client_id(_, _secret), do: nil

  defp credential_patch("microsoft365", previous, patch) do
    Enum.reduce(
      [{"clientID", "appID"}, {"clientSecret", "appPassword"}],
      patch,
      &update_equal_aliases(&1, previous, &2)
    )
  end

  defp credential_patch(_plugin, _previous, patch), do: patch

  defp update_equal_aliases({left, right}, previous, patch) do
    cond do
      not is_binary(previous[left]) or previous[left] != previous[right] ->
        patch

      Map.has_key?(patch, left) and not Map.has_key?(patch, right) ->
        Map.put(patch, right, patch[left])

      Map.has_key?(patch, right) and not Map.has_key?(patch, left) ->
        Map.put(patch, left, patch[right])

      true ->
        patch
    end
  end

  def public(row) do
    {metadata, configured_fields} =
      case Credentials.secret(row) do
        {:ok, secret} ->
          {
            Map.merge(
              row.public_metadata,
              Ankole.Connectors.LegacyConfig.public_metadata(secret)
            ),
            Ankole.Connectors.LegacyConfig.configured_credential_fields(secret, row.plugin_id)
          }

        {:error, _} ->
          {row.public_metadata, []}
      end

    row
    |> Map.from_struct()
    |> Map.take([
      :id,
      :plugin_id,
      :mode,
      :slug,
      :display_name,
      :auth_scheme,
      :is_default,
      :public_metadata,
      :status,
      :inserted_at,
      :updated_at
    ])
    |> Map.put(:public_metadata, metadata)
    |> Map.put(:configured_credential_fields, configured_fields)
  end

  def member(%Ankole.AuthZ.Actor{principal: actor}), do: member(actor)

  def member(%{uid: uid, tenant_id: tenant}) do
    if tenant == Repo.tenant_id!() do
      case Ankole.Principals.get_principal(uid) do
        {:ok, %{status: :active}} -> :ok
        _ -> {:error, :principal_inactive}
      end
    else
      {:error, :forbidden}
    end
  end

  def member(_), do: {:error, :forbidden}

  def admin(%Ankole.AuthZ.Actor{principal: actor}), do: admin(actor)

  def admin(actor) do
    with :ok <- member(actor), true <- Ankole.AuthZ.pod_admin?(actor.uid) do
      :ok
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp prepare(attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with :ok <- validate(attrs, attrs["secret"] || %{}),
         secret = canonical_secret(attrs["secret"] || %{}, attrs["plugin_id"]),
         {:ok, application} <-
           application_identity(
             attrs["plugin_id"],
             Map.merge(attrs["public_metadata"] || %{}, secret)
           ) do
      {:ok, attrs |> Map.put("secret", secret) |> Map.put("platform_application", application)}
    end
  end

  defp canonical_secret(secret, plugin) do
    Enum.reduce(
      [
        {"app_id", if(plugin == "whatsapp", do: "appId", else: "appID")},
        {"app_secret", "appSecret"},
        {"client_id", if(plugin == "dingtalk", do: "clientId", else: "clientID")},
        {"client_secret", "clientSecret"}
      ],
      secret,
      fn {source, target}, acc ->
        if Map.has_key?(acc, source),
          do: acc |> Map.put(target, acc[source]) |> Map.delete(source),
          else: acc
      end
    )
  end

  defp application_identity("google-workspace" = plugin, config) do
    with {:ok, adapter} <- Ankole.IdentityProviders.fetch_adapter(plugin),
         {:ok, module} <- Ankole.IdentityProviders.adapter_module(adapter),
         do: module.platform_application(config)
  end

  defp application_identity(plugin, config) when plugin in ["github", "linear"] do
    id = config["appID"] || config["clientID"]

    if is_binary(id) and id != "",
      do: {:ok, plugin <> ":" <> id},
      else: {:error, :platform_application_identity_unavailable}
  end

  defp application_identity(plugin, config) do
    case Registry.adapter(plugin) do
      {:ok, adapter} ->
        if function_exported?(adapter, :platform_application, 1),
          do: adapter.platform_application(config),
          else: legacy_application_identity(plugin, config)

      _ ->
        legacy_application_identity(plugin, config)
    end
  end

  defp legacy_application_identity(plugin, config) do
    adapter_id = if plugin == "microsoft365", do: "teams", else: plugin

    with {:ok, definition} <- Ankole.Signals.Adapters.fetch(adapter_id),
         module when not is_nil(module) <- definition.config_module do
      module.platform_application(Map.put_new(config, "domain", "feishu"))
    else
      _ -> {:error, :unsupported_connector}
    end
  rescue
    _ in [KeyError, FunctionClauseError] -> {:error, :platform_application_identity_unavailable}
  end

  defp validate(attrs, secret) do
    cond do
      not Enum.all?(~w(plugin_id slug auth_scheme), &(is_binary(attrs[&1]) and attrs[&1] != "")) ->
        {:error, :invalid_connection}

      not Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, attrs["slug"]) ->
        {:error, :invalid_connection_slug}

      not is_map(secret) ->
        {:error, :invalid_credentials}

      true ->
        :ok
    end
  end
end
