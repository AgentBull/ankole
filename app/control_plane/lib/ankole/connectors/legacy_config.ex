defmodule Ankole.Connectors.LegacyConfig do
  @moduledoc "Moves plugin credentials into their shared tenant connection while keeping behavior configuration in AppConfigure."
  require Ash.Query
  alias Ankole.Connectors.{AuthConfig, Credentials, Store}

  @plugins ~w(lark slack dingtalk wecom microsoft365 google-workspace discord telegram whatsapp line email)
  @plugin_ids Enum.map(@plugins, &(&1 <> "-adapter"))
  @credential_names ~w(appID appId app_id appSecret clientID clientId client_id clientSecret client_secret appKey corpId corpID agentId botToken botId secret appToken appPassword contactsSecret contactsAppSecret channelSecret channelAccessToken channelId accessToken verifyToken signingSecret verificationToken encryptKey token aesKey password username serviceAccountKey)
  @public_names ~w(domain appID appId clientID clientId corpId corpID agentId botId channelId phoneNumberId tenantID address username imapHost imapPort smtpHost smtpPort smtpSecurity)

  def credential_field?(key), do: key in @credential_names
  def public_field?(key), do: key in @public_names
  def public_metadata(config), do: Map.take(config, @public_names)

  def configured_credential_fields(secret, plugin),
    do:
      secret
      |> credential_names(plugin)
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.keys()
      |> Enum.sort()

  def current_for_configuration(current, patch) do
    if Map.has_key?(patch, "authConfigId") && patch["authConfigId"] != current["authConfigId"],
      do: current |> strip() |> Map.drop(@public_names),
      else: current
  end

  def plugin(definition) do
    key = Map.get(definition, :key) || Map.get(definition, :id) || ""

    case String.split(key, ".") do
      ["signals", id | _] when id in @plugins -> id
      ["signals", "teams" | _] -> "microsoft365"
      ["principals", "identity_providers", "entra-id" | _] -> "microsoft365"
      ["principals", "identity_providers", id | _] when id in @plugins -> id
      _ -> nil
    end
  end

  def hydrate(%{"authConfigId" => id} = config) when is_binary(id) do
    with {:ok, auth} <- Store.get_auth_config(id),
         {:ok, secret} <- Credentials.secret(auth) do
      {:ok, hydrate_credentials(config, auth, secret)}
    end
  end

  def hydrate(config), do: {:ok, config}

  def hydrate_for_configuration(%{"authConfigId" => id} = config) when is_binary(id) do
    with {:ok, auth} <- Store.get_auth_config_for_configuration(id),
         {:ok, secret} <- Credentials.secret(auth),
         supplied = extract(config),
         :ok <- compatible(secret, supplied) do
      {:ok, hydrate_credentials(config, auth, deep_merge(secret, supplied))}
    end
  end

  def hydrate_for_configuration(config), do: {:ok, config}

  defp hydrate_credentials(config, auth, secret) do
    config
    |> strip()
    |> Map.merge(auth.public_metadata)
    |> deep_merge(secret)
    |> credential_names(auth.plugin_id)
  end

  defp credential_names(config, "microsoft365") do
    Enum.reduce(
      [{"clientID", "appID"}, {"clientSecret", "appPassword"}],
      config,
      fn {identity, messaging}, config ->
        case {Map.fetch(config, identity), Map.fetch(config, messaging)} do
          {{:ok, value}, :error} -> Map.put(config, messaging, value)
          {:error, {:ok, value}} -> Map.put(config, identity, value)
          _ -> config
        end
      end
    )
  end

  defp credential_names(config, _plugin), do: config

  def validate(definition, value, validate, mode \\ :runtime) do
    if plugin(definition) && is_map(value) && value["authConfigId"] do
      hydrate = if mode == :configuration, do: &hydrate_for_configuration/1, else: &hydrate/1

      with {:ok, hydrated} <- hydrate.(value),
           {:ok, parsed} <- validate.(hydrated),
           do: {:ok, Map.put(parsed, "authConfigId", value["authConfigId"])}
    else
      validate.(value)
    end
  end

  def stored(definition, %{"authConfigId" => _} = value) do
    if plugin(definition), do: strip(value), else: value
  end

  def stored(_definition, value), do: value

  def ensure_in_tx(plugin, config, application, actor_uid \\ "system", status \\ "active")

  def ensure_in_tx(plugin, config, application, actor_uid, status)
      when plugin in ["teams", "entra-id"],
      do: ensure_in_tx("microsoft365", config, application, actor_uid, status)

  def ensure_in_tx(plugin, config, application, actor_uid, status) when plugin in @plugin_ids,
    do:
      ensure_in_tx(
        String.trim_trailing(plugin, "-adapter"),
        config,
        application,
        actor_uid,
        status
      )

  def ensure_in_tx(plugin, config, application, actor_uid, status) when plugin in @plugins do
    credential = extract(config)

    if config["authConfigId"] do
      with {:ok, auth} <- Store.get_auth_config_for_configuration(config["authConfigId"], plugin),
           {:ok, auth} <-
             merge_or_create(auth, plugin, credential, application, actor_uid, config, status),
           do: {:ok, config, auth.id}
    else
      fingerprint = application || fingerprint(plugin, credential)

      :ok = Store.lock_default_in_tx(plugin)
      existing = existing_config(plugin, fingerprint, credential)

      with {:ok, auth} <-
             merge_or_create(existing, plugin, credential, fingerprint, actor_uid, config, status) do
        {:ok, Map.put(config, "authConfigId", auth.id), auth.id}
      end
    end
  end

  def ensure_in_tx(_plugin, config, _application, _actor_uid, _status), do: {:ok, config, nil}

  defp existing_config("slack", application, %{"clientID" => client_id}) do
    AuthConfig
    |> Ash.Query.filter(
      plugin_id == "slack" and
        (platform_application == ^application or platform_client_id == ^client_id)
    )
    |> Ankole.Ash.read_one!()
  end

  defp existing_config(plugin, application, _credential) do
    AuthConfig
    |> Ash.Query.filter(plugin_id == ^plugin and platform_application == ^application)
    |> Ankole.Ash.read_one!()
  end

  defp merge_or_create(nil, plugin, credential, application, actor_uid, config, status) do
    has_default =
      AuthConfig
      |> Ash.Query.filter(plugin_id == ^plugin and is_default == true and status == "active")
      |> Ankole.Ash.exists?()

    slug =
      plugin <>
        "-" <> binary_part(Base.encode16(:crypto.hash(:sha256, application), case: :lower), 0, 12)

    Store.create_in_tx(actor_uid, %{
      "plugin_id" => plugin,
      "slug" => slug,
      "auth_scheme" => scheme(plugin),
      "display_name" => plugin,
      "secret" => credential,
      "is_default" => status == "active" and not has_default,
      "status" => status,
      "platform_application" => application,
      "public_metadata" => public_metadata(config)
    })
  end

  defp merge_or_create(existing, _plugin, credential, application, _actor_uid, _config, _status) do
    existing = Store.lock(existing.id)

    with {:ok, previous} <- Credentials.secret(existing),
         :ok <- compatible(previous, credential),
         merged = deep_merge(previous, credential),
         {:ok, changes} <- Store.credential_changes(existing, application, previous, merged),
         do: Store.update_in_tx(existing, changes)
  end

  defp compatible(left, right) do
    conflicts =
      for {key, value} <- right,
          Map.has_key?(left, key),
          left[key] not in [nil, ""],
          left[key] != value,
          not is_nil(value),
          do: key

    if conflicts == [], do: :ok, else: {:error, {:credential_conflict, Enum.sort(conflicts)}}
  end

  defp extract(map),
    do:
      Map.new(map, fn {key, value} -> {key, value} end)
      |> Map.take(@credential_names)
      |> Map.reject(fn {_key, value} -> is_nil(value) or value == "" end)

  defp strip(map), do: Map.drop(map, @credential_names)

  defp deep_merge(left, right),
    do:
      Map.merge(left, right, fn _key, l, r ->
        if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
      end)

  defp fingerprint(plugin, credential) do
    id =
      credential["appID"] || credential["appId"] || credential["clientID"] ||
        credential["clientId"] || credential["botId"] || credential["channelId"]

    if is_binary(id),
      do: plugin <> ":" <> id,
      else:
        plugin <>
          ":" <>
          Base.encode16(
            :crypto.hash(
              :sha256,
              Ankole.JSON.encode!(
                Enum.map(Enum.sort(credential), fn {key, value} -> [key, value] end)
              )
            ),
            case: :lower
          )
  end

  defp scheme("lark"), do: "lark_app"
  defp scheme("email"), do: "imap_smtp"
  defp scheme(_), do: "platform_app"
end
