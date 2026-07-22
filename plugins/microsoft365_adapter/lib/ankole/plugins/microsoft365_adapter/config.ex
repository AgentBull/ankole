defmodule Ankole.Plugins.Microsoft365Adapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party Microsoft 365 adapter."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias MicrosoftOpenAPI.Client

  @chat_key_pattern ~r/\Asignals_gateway\.teams\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.entra-id\.[A-Za-z0-9_.:-]+\z/
  @subscription_key_pattern ~r/\Aprincipals\.entra_id\.graph_subscriptions\.[A-Za-z0-9_.:-]+\z/

  @default_oidc_scopes ["openid", "profile", "email", "User.Read"]
  @default_namespace "entra-id-main"
  @multi_tenant_bot_token_tenant "botframework.com"
  @guid_pattern ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @type chat_config :: map()
  @type identity_config :: map()

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals_gateway.teams.bindings.*",
        key_pattern: @chat_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted Microsoft Teams chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.entra-id.*",
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted Entra ID identity-provider configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.entra_id.graph_subscriptions.*",
        key_pattern: @subscription_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_subscription_state/1),
        description: "Machine-managed Graph change-notification subscription state."
      )
    ]
  end

  @spec chat_config_key(String.t()) :: String.t()
  def chat_config_key(id), do: "signals_gateway.teams.bindings.#{id}"

  @spec identity_config_key(String.t()) :: String.t()
  def identity_config_key(id), do: "principals.identity_providers.entra-id.#{id}"

  @spec subscription_state_key(String.t()) :: String.t()
  def subscription_state_key(provider_id),
    do: "principals.entra_id.graph_subscriptions.#{provider_id}"

  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, app_id} <- required_guid(value, "appID"),
         {:ok, app_password} <- required_string(value, "appPassword"),
         {:ok, tenancy} <-
           select(value, "botTenancy", "single_tenant", ["single_tenant", "multi_tenant"]),
         {:ok, tenant_id} <- tenant_for_tenancy(value, tenancy),
         {:ok, namespace} <-
           optional_string(value, "platformSubjectNamespace", @default_namespace),
         {:ok, user_name} <- optional_string(value, "userName", "Teams") do
      {:ok,
       %{
         "appID" => app_id,
         "appPassword" => app_password,
         "botTenancy" => tenancy,
         "tenantID" => tenant_id,
         "platformSubjectNamespace" => namespace,
         "userName" => user_name
       }}
    end
  end

  def validate_chat_config(_value), do: {:error, :invalid_chat_config}

  @spec validate_binding_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_binding_config(value), do: validate_chat_config(value)

  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    oidc = MapHelpers.fetch_map(value, "oidc", %{})
    sync = MapHelpers.fetch_map(value, "sync", %{})

    with {:ok, tenant_id} <- required_guid(value, "tenantID"),
         {:ok, client_id} <- required_string(value, "clientID"),
         {:ok, client_secret} <- required_string(value, "clientSecret"),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, oidc_scopes} <- string_array(oidc, "scopes", @default_oidc_scopes),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         {:ok, requested_realtime} <- optional_boolean(sync, "realtime", true),
         {:ok, page_size} <- integer_between(sync, "pageSize", 999, 1, 999),
         {:ok, groups_filter} <- optional_string(sync, "groupsFilter", nil),
         {:ok, include_guests} <- optional_boolean(sync, "includeGuests", false),
         {:ok, public_base_url} <- optional_base_url(value, "publicBaseURL"),
         sync_realtime = requested_realtime and sync_contacts,
         :ok <- require_when(sync_realtime, public_base_url, "publicBaseURL") do
      {:ok,
       %{
         "tenantID" => tenant_id,
         "clientID" => client_id,
         "clientSecret" => client_secret,
         "oidc" => %{"enabled" => oidc_enabled, "scopes" => oidc_scopes},
         "sync" => %{
           "contacts" => sync_contacts,
           "realtime" => sync_realtime,
           "pageSize" => page_size,
           "groupsFilter" => groups_filter,
           "includeGuests" => include_guests
         },
         "publicBaseURL" => public_base_url
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

  @doc """
  Validates machine-managed Graph subscription state.

  Shape: `%{"subscriptions" => [%{"id", "resource", "expiration", "clientState"}]}`.
  """
  @spec validate_subscription_state(term()) :: {:ok, map()} | {:error, term()}
  def validate_subscription_state(%{"subscriptions" => subscriptions})
      when is_list(subscriptions) do
    if Enum.all?(subscriptions, &valid_subscription_entry?/1) do
      {:ok, %{"subscriptions" => subscriptions}}
    else
      {:error, :invalid_graph_subscription_state}
    end
  end

  def validate_subscription_state(_value), do: {:error, :invalid_graph_subscription_state}

  @spec load_chat_config_ref(String.t()) :: {:ok, chat_config()} | {:error, term()} | :error
  def load_chat_config_ref(config_ref) when is_binary(config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_by_key(key) do
      validate_chat_config(value)
    end
  end

  def load_chat_config_ref(_config_ref), do: {:error, :invalid_config_ref}

  @spec load_identity_config_key(String.t()) :: {:ok, identity_config()} | {:error, term()}
  def load_identity_config_key(key) when is_binary(key) do
    with {:ok, value} <- AppConfigure.get_by_key(key), do: validate_identity_config(value)
  end

  def load_identity_config_key(_key), do: {:error, :invalid_config_key}

  @doc """
  Builds a provider client from a chat config.

  The Bot Connector token tenant follows the declared tenancy: the bot's own
  tenant for single-tenant apps, the fixed `botframework.com` segment for
  multi-tenant apps.
  """
  @spec chat_client(chat_config()) :: Client.t()
  def chat_client(config) do
    Client.new(
      tenant_id: Map.get(config, "tenantID"),
      client_id: Map.fetch!(config, "appID"),
      client_secret: Map.fetch!(config, "appPassword"),
      bot_token_tenant: bot_token_tenant(config)
    )
  end

  @spec identity_client(identity_config()) :: Client.t()
  def identity_client(config) do
    Client.new(
      tenant_id: Map.fetch!(config, "tenantID"),
      client_id: Map.fetch!(config, "clientID"),
      client_secret: Map.fetch!(config, "clientSecret")
    )
  end

  @spec bot_token_tenant(chat_config()) :: String.t()
  def bot_token_tenant(%{"botTenancy" => "multi_tenant"}), do: @multi_tenant_bot_token_tenant
  def bot_token_tenant(config), do: Map.fetch!(config, "tenantID")

  @spec namespace(chat_config()) :: String.t()
  def namespace(config),
    do: Map.get(config, "platformSubjectNamespace") || @default_namespace

  defp valid_subscription_entry?(entry) when is_map(entry) do
    is_binary(MapHelpers.optional_text(entry, "id")) and
      is_binary(MapHelpers.optional_text(entry, "resource")) and
      is_binary(MapHelpers.optional_text(entry, "clientState"))
  end

  defp valid_subscription_entry?(_entry), do: false

  defp tenant_for_tenancy(value, "single_tenant"), do: required_guid(value, "tenantID")

  defp tenant_for_tenancy(value, "multi_tenant") do
    case MapHelpers.optional_text(value, "tenantID") do
      nil -> {:ok, nil}
      tenant -> validate_guid(tenant, "tenantID")
    end
  end

  defp required_guid(map, key) do
    with {:ok, value} <- required_string(map, key) do
      validate_guid(value, key)
    end
  end

  defp validate_guid(value, key) do
    if Regex.match?(@guid_pattern, value) do
      {:ok, String.downcase(value)}
    else
      {:error, {:invalid_guid, key}}
    end
  end

  defp select(map, key, default, allowed) do
    case MapHelpers.optional_text(map, key) do
      nil ->
        {:ok, default}

      value ->
        if value in allowed, do: {:ok, value}, else: {:error, {:invalid_select, key, allowed}}
    end
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key), do: {:ok, key}

  defp require_when(true, nil, key), do: {:error, {:missing, key}}
  defp require_when(_enabled, _value, _key), do: :ok

  defp required_string(map, key) do
    case MapHelpers.optional_text(map, key) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, MapHelpers.presence(value) || default}
      _value -> {:error, {:invalid_string, key}}
    end
  end

  defp optional_base_url(map, key) do
    with {:ok, value} <- optional_string(map, key, nil) do
      case value do
        nil ->
          {:ok, nil}

        url ->
          case URI.parse(url) do
            %URI{scheme: scheme, host: host}
            when scheme in ["http", "https"] and is_binary(host) ->
              {:ok, String.trim_trailing(url, "/")}

            _uri ->
              {:error, {:invalid_base_url, key}}
          end
      end
    end
  end

  defp optional_boolean(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp integer_between(map, key, default, min, max) do
    case MapHelpers.fetch_value(map, key) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_integer_range, key, min, max}}
    end
  end

  defp string_array(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:error, {:invalid_string_array, key}}
        end

      nil ->
        {:ok, default}

      _value ->
        {:error, {:invalid_string_array, key}}
    end
  end
end
