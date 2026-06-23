defmodule Ankole.Plugins.LarkAdapter.Config do
  @moduledoc """
  Validation and runtime helpers for the first-party Lark / Feishu adapter.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias FeishuOpenAPI.Client

  @chat_key_pattern ~r/\Asignals_gateway\.lark\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.lark\.[A-Za-z0-9_.:-]+\z/
  @domains ["feishu", "lark"]
  @group_message_modes ["addressed_only", "observe_all", "may_intervene"]
  @default_oidc_scopes ["contact:user.employee_id:readonly"]

  @type chat_config :: map()
  @type identity_config :: map()

  @doc """
  AppConfigure key patterns contributed by the plugin.
  """
  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals_gateway.lark.bindings.*",
        key_pattern: @chat_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted Lark / Feishu chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.lark.*",
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted Lark / Feishu identity-provider configuration."
      )
    ]
  end

  @spec chat_config_key(String.t()) :: String.t()
  @doc """
  Builds the AppConfigure key for one chat binding.
  """
  def chat_config_key(id), do: "signals_gateway.lark.bindings.#{id}"

  @spec identity_config_key(String.t()) :: String.t()
  @doc """
  Builds the AppConfigure key for one identity-provider instance.
  """
  def identity_config_key(id), do: "principals.identity_providers.lark.#{id}"

  @doc """
  Normalizes and validates chat binding configuration loaded from AppConfigure.
  """
  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, app_id} <- required_string(value, "appId"),
         {:ok, app_secret} <- required_string(value, "appSecret"),
         {:ok, domain} <- enum_string(value, "domain", @domains, "feishu"),
         {:ok, group_message_mode} <-
           enum_string(value, "group_message_mode", @group_message_modes, "observe_all"),
         {:ok, platform_subject_namespace} <-
           optional_string(value, "platformSubjectNamespace", "lark-main"),
         {:ok, user_name} <- optional_string(value, "userName", "Lark / Feishu"),
         {:ok, streaming_enabled} <- optional_boolean(value, "streamingEnabled", true),
         {:ok, stream_update_interval_ms} <-
           integer_between(value, "streamUpdateIntervalMs", 800, 100, 60_000),
         {:ok, stream_buffer_threshold} <-
           integer_between(value, "streamBufferThreshold", 24, 1, 10_000) do
      {:ok,
       %{
         "appId" => app_id,
         "appSecret" => app_secret,
         "domain" => domain,
         "group_message_mode" => group_message_mode,
         "platformSubjectNamespace" => platform_subject_namespace,
         "userName" => user_name,
         "streamingEnabled" => streaming_enabled,
         "streamUpdateIntervalMs" => stream_update_interval_ms,
         "streamBufferThreshold" => stream_buffer_threshold
       }}
    end
  end

  def validate_chat_config(_value), do: {:error, :invalid_chat_config}

  @doc """
  Normalizes and validates identity-provider configuration loaded from AppConfigure.
  """
  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    with {:ok, app_id} <- required_string(value, "appId"),
         {:ok, app_secret} <- required_string(value, "appSecret"),
         {:ok, domain} <- enum_string(value, "domain", @domains, "feishu"),
         oidc <- fetch_map(value, "oidc", %{}),
         sync <- fetch_map(value, "sync", %{}),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, oidc_scopes} <- string_array(oidc, "scopes", @default_oidc_scopes),
         {:ok, sync_users} <- optional_boolean(sync, "users", true),
         {:ok, sync_departments} <- optional_boolean(sync, "departments", true),
         {:ok, sync_websocket} <- optional_boolean(sync, "websocket", true),
         {:ok, sync_page_size} <- integer_between(sync, "pageSize", 50, 1, 50) do
      {:ok,
       %{
         "appId" => app_id,
         "appSecret" => app_secret,
         "domain" => domain,
         "oidc" => %{"enabled" => oidc_enabled, "scopes" => oidc_scopes},
         "sync" => %{
           "users" => sync_users,
           "departments" => sync_departments,
           "websocket" => sync_websocket,
           "pageSize" => sync_page_size
         }
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

  @doc """
  Loads a chat config referenced by a SignalsGateway binding `config_ref`.
  """
  @spec load_chat_config_ref(String.t()) :: {:ok, chat_config()} | {:error, term()} | :error
  def load_chat_config_ref(config_ref) when is_binary(config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_by_key(key) do
      validate_chat_config(value)
    end
  end

  def load_chat_config_ref(_config_ref), do: {:error, :invalid_config_ref}

  @doc """
  Builds a FeishuOpenAPI client without exposing the secret in inspect output.
  """
  @spec client(chat_config() | identity_config(), keyword()) :: Client.t()
  def client(config, opts \\ []) when is_map(config) do
    Client.new(
      Map.fetch!(config, "appId"),
      fn -> Map.fetch!(config, "appSecret") end,
      Keyword.merge([domain: domain_atom(Map.fetch!(config, "domain"))], opts)
    )
  end

  @doc """
  Returns the stable local connection key for config that shares one Lark app.
  """
  @spec connection_key(chat_config() | identity_config()) :: {String.t(), String.t()}
  def connection_key(config), do: {Map.fetch!(config, "domain"), Map.fetch!(config, "appId")}

  @doc """
  Fingerprints a secret for conflict detection without storing the secret in state.
  """
  @spec secret_fingerprint(chat_config() | identity_config()) :: String.t()
  def secret_fingerprint(config) do
    :sha256
    |> :crypto.hash(Map.fetch!(config, "appSecret"))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Converts setup's group-message mode into SignalsGateway binding policy.
  """
  @spec group_message_policy(String.t()) :: :ignore | :record_only | :may_intervene
  def group_message_policy("addressed_only"), do: :ignore
  def group_message_policy("observe_all"), do: :record_only
  def group_message_policy("may_intervene"), do: :may_intervene

  @doc """
  Returns the provider base URL for the configured Lark product region.
  """
  @spec domain_base_url(String.t()) :: String.t()
  def domain_base_url("feishu"), do: Client.base_url_for(:feishu)
  def domain_base_url("lark"), do: Client.base_url_for(:lark)

  @doc """
  Converts stored string config into the atom expected by FeishuOpenAPI.
  """
  @spec domain_atom(String.t()) :: :feishu | :lark
  def domain_atom("feishu"), do: :feishu
  def domain_atom("lark"), do: :lark

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key) when is_binary(key), do: {:ok, key}

  defp required_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp optional_string(map, key, default) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, default}

      _value ->
        {:error, {:invalid_string, key}}
    end
  end

  defp enum_string(map, key, values, default) do
    with {:ok, value} <- optional_string(map, key, default) do
      case value in values do
        true -> {:ok, value}
        false -> {:error, {:invalid_enum, key, values}}
      end
    end
  end

  defp optional_boolean(map, key, default) do
    case fetch_value(map, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp integer_between(map, key, default, min, max) do
    case fetch_value(map, key) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_integer_range, key, min, max}}
    end
  end

  defp string_array(map, key, default) do
    case fetch_value(map, key) do
      values when is_list(values) ->
        case Enum.all?(values, &is_binary/1) do
          true -> {:ok, values}
          false -> {:error, {:invalid_string_array, key}}
        end

      nil ->
        {:ok, default}

      _value ->
        {:error, {:invalid_string_array, key}}
    end
  end

  defp fetch_map(map, key, default) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      nil -> default
      _value -> default
    end
  end

  defp fetch_value(map, key) do
    atom_key = atom_key(key)

    # Config may arrive from JSON with string keys or from tests/setup helpers
    # with atom keys. `to_existing_atom` below avoids creating atoms from input.
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      true -> nil
    end
  end

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
