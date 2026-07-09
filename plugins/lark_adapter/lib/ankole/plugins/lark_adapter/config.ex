defmodule Ankole.Plugins.LarkAdapter.Config do
  @moduledoc """
  Validation and runtime helpers for the first-party Lark / Feishu adapter.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.MapHelpers
  alias FeishuOpenAPI.Client

  @chat_key_pattern ~r/\Asignals_gateway\.lark\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.lark\.[A-Za-z0-9_.:-]+\z/
  @domains ["feishu", "lark"]
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
         {:ok, base_url} <- optional_base_url(value, "baseUrl"),
         {:ok, platform_subject_namespace} <-
           optional_string(value, "platformSubjectNamespace", "lark-main"),
         {:ok, user_name} <- optional_string(value, "userName", "Lark / Feishu"),
         {:ok, bot_open_id} <- optional_string(value, "botOpenId", nil),
         {:ok, bot_user_id} <- optional_string(value, "botUserId", nil) do
      {:ok,
       %{
         "appId" => app_id,
         "appSecret" => app_secret,
         "domain" => domain,
         "baseUrl" => base_url,
         "platformSubjectNamespace" => platform_subject_namespace,
         "userName" => user_name,
         "botOpenId" => bot_open_id,
         "botUserId" => bot_user_id
       }}
    end
  end

  def validate_chat_config(_value), do: {:error, :invalid_chat_config}

  @doc """
  Validates chat config when it is used as a SignalsGateway binding.

  A binding needs no extra input beyond the chat config: the bot's own
  `open_id` is resolved from `bot/v3/info` at connection time, so operators are
  never asked to supply a bot identity by hand.
  """
  @spec validate_binding_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_binding_config(value), do: validate_chat_config(value)

  @doc """
  Normalizes and validates identity-provider configuration loaded from AppConfigure.
  """
  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    with {:ok, app_id} <- required_string(value, "appId"),
         {:ok, app_secret} <- required_string(value, "appSecret"),
         {:ok, domain} <- enum_string(value, "domain", @domains, "feishu"),
         oidc <- MapHelpers.fetch_map(value, "oidc", %{}),
         sync <- MapHelpers.fetch_map(value, "sync", %{}),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, oidc_scopes} <- string_array(oidc, "scopes", @default_oidc_scopes),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         {:ok, sync_websocket} <- optional_boolean(sync, "websocket", true),
         {:ok, sync_page_size} <- integer_between(sync, "pageSize", 50, 1, 50) do
      sync_websocket = sync_websocket and sync_contacts

      {:ok,
       %{
         "appId" => app_id,
         "appSecret" => app_secret,
         "domain" => domain,
         "oidc" => %{"enabled" => oidc_enabled, "scopes" => oidc_scopes},
         "sync" => %{
           "contacts" => sync_contacts,
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
  Loads an identity-provider config by its AppConfigure key.
  """
  @spec load_identity_config_key(String.t()) :: {:ok, identity_config()} | {:error, term()}
  def load_identity_config_key(key) when is_binary(key) do
    with {:ok, value} <- AppConfigure.get_by_key(key) do
      validate_identity_config(value)
    end
  end

  def load_identity_config_key(_key), do: {:error, :invalid_config_key}

  @doc """
  Builds a FeishuOpenAPI client without exposing the secret in inspect output.

  A configured `baseUrl` overrides the domain-derived provider URL for both the
  WS endpoint discovery and HTTP calls; explicit `opts` still win over config.
  """
  @spec client(chat_config() | identity_config(), keyword()) :: Client.t()
  def client(config, opts \\ []) when is_map(config) do
    base_opts =
      case Map.get(config, "baseUrl") do
        base_url when is_binary(base_url) -> [base_url: base_url]
        _absent -> []
      end

    Client.new(
      Map.fetch!(config, "appId"),
      fn -> Map.fetch!(config, "appSecret") end,
      [domain: domain_atom(Map.fetch!(config, "domain"))]
      |> Keyword.merge(base_opts)
      |> Keyword.merge(opts)
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
  Adds the provider-derived bot `open_id` to a chat config without persisting it.

  The console never asks operators for a bot identity. Group mention events
  carry the mentioned bot's `open_id`, so the adapter resolves its own
  `open_id` from `bot/v3/info` (using the app credentials alone) while building
  the live connection and keeps it only in the process-local consumer config as
  `runtimeBotOpenId`. A config that already carries an explicit `botOpenId`
  override is left untouched.
  """
  @spec resolve_runtime_bot_identity(chat_config(), keyword()) :: chat_config()
  def resolve_runtime_bot_identity(config, opts \\ []) when is_map(config) do
    if present_string?(Map.get(config, "botOpenId")) do
      config
    else
      fetcher = Keyword.get(opts, :bot_info_fetcher, &fetch_runtime_bot_open_id/1)

      case fetcher.(config) do
        {:ok, open_id} when is_binary(open_id) ->
          Map.put(config, "runtimeBotOpenId", String.trim(open_id))

        {:error, reason} ->
          Logging.warning(
            "lark_adapter.config.runtime_bot_open_id_failed",
            "lark adapter could not resolve runtime bot open_id",
            %{
              app_id: Map.get(config, "appId"),
              reason: inspect(reason)
            }
          )

          config
      end
    end
  end

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

  defp fetch_runtime_bot_open_id(config) do
    case FeishuOpenAPI.get(client(config), "bot/v3/info") do
      {:ok, %{"bot" => %{"open_id" => open_id}}} when is_binary(open_id) ->
        case String.trim(open_id) do
          "" -> {:error, :missing_bot_open_id}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _body} ->
        {:error, :missing_bot_open_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key) when is_binary(key), do: {:ok, key}

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

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

  defp string_array(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
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
end
