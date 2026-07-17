defmodule Ankole.Plugins.DingTalkAdapter.Config do
  @moduledoc """
  Validation and runtime helpers for the first-party DingTalk adapter.

  DingTalk enterprise-internal apps authenticate with an AppKey (`clientId`) and
  AppSecret (`clientSecret`), which double as the Stream `clientId`/`clientSecret`.
  One agent gets at most one enabled DingTalk binding, and one `clientId` cannot
  be assigned to two agents.
  """

  import Ecto.Query, warn: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Binding
  alias DingTalkOpenAPI.Client

  @chat_key_pattern ~r/\Asignals_gateway\.dingtalk\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.dingtalk\.[A-Za-z0-9_.:-]+\z/
  @group_message_modes ["addressed_only"]
  @oidc_scopes ["openid", "openid corpid"]

  @type chat_config :: map()
  @type identity_config :: map()

  @doc "Exact AppConfigure definitions contributed by the plugin."
  @spec app_config_definitions() :: []
  def app_config_definitions, do: []

  @doc "AppConfigure key patterns contributed by the plugin."
  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals_gateway.dingtalk.bindings.*",
        key_pattern: @chat_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted DingTalk chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.dingtalk.*",
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted DingTalk identity-provider configuration."
      )
    ]
  end

  @spec chat_config_key(String.t()) :: String.t()
  def chat_config_key(id), do: "signals_gateway.dingtalk.bindings.#{id}"

  @spec identity_config_key(String.t()) :: String.t()
  def identity_config_key(id), do: "principals.identity_providers.dingtalk.#{id}"

  @doc "Normalizes and validates chat binding configuration loaded from AppConfigure."
  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, client_id} <- required_string(value, "clientId"),
         {:ok, client_secret} <- required_string(value, "clientSecret"),
         {:ok, robot_code} <- optional_string(value, "robotCode", nil),
         {:ok, card_template_id} <- optional_string(value, "cardTemplateId", nil),
         {:ok, group_message_mode} <-
           enum_string(value, "group_message_mode", @group_message_modes, "addressed_only"),
         {:ok, base_url} <- optional_base_url(value, "baseURL"),
         {:ok, platform_subject_namespace} <-
           optional_string(value, "platformSubjectNamespace", "dingtalk-main"),
         {:ok, user_name} <- optional_string(value, "userName", "钉钉 / DingTalk") do
      {:ok,
       %{
         "clientId" => client_id,
         "clientSecret" => client_secret,
         "robotCode" => robot_code,
         "cardTemplateId" => card_template_id,
         "group_message_mode" => group_message_mode,
         "baseURL" => base_url,
         "platformSubjectNamespace" => platform_subject_namespace,
         "userName" => user_name
       }}
    end
  end

  def validate_chat_config(_value), do: {:error, :invalid_chat_config}

  @doc """
  Validates chat config when used as a SignalsGateway binding. A binding needs no
  extra input beyond the chat config: the robot's own encrypted id arrives on
  every inbound frame, so operators never supply a bot identity by hand.
  """
  @spec validate_binding_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_binding_config(value), do: validate_chat_config(value)

  @doc """
  Enforces the one-agent/one-DingTalk-app assignment. Updating the current
  binding is allowed; disabled bindings do not reserve an app.
  """
  @spec validate_binding_assignment(String.t(), String.t(), chat_config()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(agent_uid, binding_name, config)
      when is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    with :ok <- ensure_single_enabled_binding(agent_uid, binding_name),
         :ok <- ensure_app_not_bound_to_another_agent(agent_uid, Map.fetch!(config, "clientId")) do
      :ok
    end
  end

  @doc "Normalizes and validates identity-provider configuration loaded from AppConfigure."
  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    with {:ok, client_id} <- required_string(value, "clientId"),
         {:ok, client_secret} <- required_string(value, "clientSecret"),
         oidc <- MapHelpers.fetch_map(value, "oidc", %{}),
         sync <- MapHelpers.fetch_map(value, "sync", %{}),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, oidc_scope} <- enum_string(oidc, "scope", @oidc_scopes, "openid corpid"),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         {:ok, sync_websocket} <- optional_boolean(sync, "websocket", true),
         {:ok, sync_page_size} <- integer_between(sync, "pageSize", 50, 1, 100) do
      sync_websocket = sync_websocket and sync_contacts

      {:ok,
       %{
         "clientId" => client_id,
         "clientSecret" => client_secret,
         "oidc" => %{"enabled" => oidc_enabled, "scope" => oidc_scope},
         "sync" => %{
           "contacts" => sync_contacts,
           "websocket" => sync_websocket,
           "pageSize" => sync_page_size
         }
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

  @doc "Loads a chat config referenced by a SignalsGateway binding `config_ref`."
  @spec load_chat_config_ref(String.t()) :: {:ok, chat_config()} | {:error, term()} | :error
  def load_chat_config_ref(config_ref) when is_binary(config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_by_key(key) do
      validate_chat_config(value)
    end
  end

  def load_chat_config_ref(_config_ref), do: {:error, :invalid_config_ref}

  @doc "Loads an identity-provider config by its AppConfigure key."
  @spec load_identity_config_key(String.t()) :: {:ok, identity_config()} | {:error, term()}
  def load_identity_config_key(key) when is_binary(key) do
    with {:ok, value} <- AppConfigure.get_by_key(key) do
      validate_identity_config(value)
    end
  end

  def load_identity_config_key(_key), do: {:error, :invalid_config_key}

  @doc """
  Builds a DingTalkOpenAPI client without exposing the secret in inspect output.
  A configured `baseURL` overrides both the new- and old-domain base URLs (local
  end-to-end fakes only); explicit `opts` still win.
  """
  @spec client(chat_config() | identity_config(), keyword()) :: Client.t()
  def client(config, opts \\ []) when is_map(config) do
    base_opts =
      case Map.get(config, "baseURL") do
        base_url when is_binary(base_url) ->
          [api_base_url: base_url, oapi_base_url: base_url]

        _absent ->
          []
      end

    Client.new(
      [
        client_id: Map.fetch!(config, "clientId"),
        client_secret: fn -> Map.fetch!(config, "clientSecret") end
      ]
      |> Keyword.merge(base_opts)
      |> Keyword.merge(opts)
    )
  end

  @doc "Returns the stable local connection key for config that shares one DingTalk app."
  @spec connection_key(chat_config() | identity_config()) :: {String.t(), String.t()}
  def connection_key(config), do: {"dingtalk", Map.fetch!(config, "clientId")}

  @doc "Returns the robot code to send as, defaulting to the AppKey when unset."
  @spec effective_robot_code(chat_config()) :: String.t()
  def effective_robot_code(config) do
    case MapHelpers.optional_text(config, "robotCode") do
      nil -> Map.fetch!(config, "clientId")
      robot_code -> robot_code
    end
  end

  @doc "Fingerprints a secret for conflict detection without storing the secret in state."
  @spec secret_fingerprint(chat_config() | identity_config()) :: String.t()
  def secret_fingerprint(config) do
    :sha256
    |> :crypto.hash(Map.fetch!(config, "clientSecret"))
    |> Base.encode16(case: :lower)
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key) when is_binary(key), do: {:ok, key}

  defp ensure_single_enabled_binding(agent_uid, binding_name) do
    existing? =
      Binding
      |> where(
        [binding],
        binding.agent_uid == ^agent_uid and binding.adapter == "dingtalk" and
          binding.enabled == true and binding.name != ^binding_name
      )
      |> Repo.exists?()

    if existing?, do: {:error, :dingtalk_binding_already_exists}, else: :ok
  end

  defp ensure_app_not_bound_to_another_agent(agent_uid, client_id) do
    Binding
    |> where(
      [binding],
      binding.adapter == "dingtalk" and binding.enabled == true and
        binding.agent_uid != ^agent_uid
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case load_chat_config_ref(binding.config_ref) do
        {:ok, %{"clientId" => ^client_id}} ->
          {:halt, {:error, {:dingtalk_app_already_bound, client_id, binding.agent_uid}}}

        _other ->
          {:cont, :ok}
      end
    end)
  end

  defp required_string(map, key) do
    case MapHelpers.fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, {:missing, key}}
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
              {:ok, url}

            _uri ->
              {:error, {:invalid_base_url, key}}
          end
      end
    end
  end

  defp optional_string(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
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
end
