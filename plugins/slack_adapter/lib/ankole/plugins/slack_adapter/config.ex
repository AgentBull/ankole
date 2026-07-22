defmodule Ankole.Plugins.SlackAdapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party Slack adapter."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Logging
  alias Ankole.Plugins.MapHelpers
  alias SlackOpenAPI.Client

  @chat_key_pattern ~r/\Asignals_gateway\.slack\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.slack\.[A-Za-z0-9_.:-]+\z/
  @default_oidc_scopes ["openid", "profile", "email"]

  @type chat_config :: map()
  @type identity_config :: map()

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals_gateway.slack.bindings.*",
        key_pattern: @chat_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted Slack chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.slack.*",
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted Slack identity-provider configuration."
      )
    ]
  end

  @spec chat_config_key(String.t()) :: String.t()
  def chat_config_key(id), do: "signals_gateway.slack.bindings.#{id}"

  @spec identity_config_key(String.t()) :: String.t()
  def identity_config_key(id), do: "principals.identity_providers.slack.#{id}"

  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, bot_token} <- required_string(value, "botToken"),
         :ok <- token_prefix(bot_token, "xoxb-", "botToken"),
         {:ok, app_token} <- required_string(value, "appToken"),
         :ok <- token_prefix(app_token, "xapp-", "appToken"),
         {:ok, namespace} <- optional_string(value, "platformSubjectNamespace", "slack-main"),
         {:ok, user_name} <- optional_string(value, "userName", "Slack"),
         {:ok, bot_user_id} <- optional_string(value, "botUserID", nil) do
      {:ok,
       %{
         "botToken" => bot_token,
         "appToken" => app_token,
         "platformSubjectNamespace" => namespace,
         "userName" => user_name,
         "botUserID" => bot_user_id
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

    with {:ok, client_id} <- required_string(value, "clientID"),
         {:ok, client_secret} <- required_string(value, "clientSecret"),
         {:ok, team_id} <- optional_string(value, "teamID", nil),
         {:ok, bot_token} <- optional_string(value, "botToken", nil),
         :ok <- optional_token_prefix(bot_token, "xoxb-", "botToken"),
         {:ok, app_token} <- optional_string(value, "appToken", nil),
         :ok <- optional_token_prefix(app_token, "xapp-", "appToken"),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, oidc_scopes} <- string_array(oidc, "scopes", @default_oidc_scopes),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         {:ok, requested_websocket} <- optional_boolean(sync, "websocket", true),
         {:ok, page_size} <- integer_between(sync, "pageSize", 200, 1, 200),
         :ok <- require_when(sync_contacts, bot_token, "botToken"),
         sync_websocket = requested_websocket and sync_contacts,
         :ok <- require_when(sync_websocket, app_token, "appToken") do
      {:ok,
       %{
         "clientID" => client_id,
         "clientSecret" => client_secret,
         "teamID" => team_id,
         "botToken" => bot_token,
         "appToken" => app_token,
         "oidc" => %{"enabled" => oidc_enabled, "scopes" => oidc_scopes},
         "sync" => %{
           "contacts" => sync_contacts,
           "websocket" => sync_websocket,
           "pageSize" => page_size
         }
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

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

  @spec client(chat_config() | identity_config()) :: Client.t()
  def client(config) do
    Client.new(bot_token: Map.get(config, "botToken"), app_token: Map.get(config, "appToken"))
  end

  @spec connection_key(chat_config() | identity_config()) :: {String.t(), String.t()}
  def connection_key(config) do
    fingerprint = token_fingerprint(Map.fetch!(config, "appToken"))
    {"slack", binary_part(fingerprint, 0, 16)}
  end

  @spec secret_fingerprint(chat_config() | identity_config()) :: String.t()
  def secret_fingerprint(config) do
    :sha256
    |> :crypto.hash(
      Map.fetch!(config, "appToken") <> <<0>> <> (Map.get(config, "botToken") || "")
    )
    |> Base.encode16(case: :lower)
  end

  @spec resolve_runtime_bot_identity(chat_config()) :: chat_config()
  def resolve_runtime_bot_identity(config) do
    if MapHelpers.presence(Map.get(config, "botUserID")) do
      config
    else
      case fetch_runtime_bot_identity(config) do
        {:ok, identity} ->
          config
          |> maybe_map_put("runtimeBotUserID", Map.get(identity, "user_id"))
          |> maybe_map_put("runtimeBotID", Map.get(identity, "bot_id"))
          |> maybe_map_put("runtimeTeamID", Map.get(identity, "team_id"))

        {:error, reason} ->
          Logging.warning(
            "slack_adapter.config.runtime_bot_identity_failed",
            "slack adapter could not resolve runtime bot identity",
            %{connection_key: inspect(connection_key(config)), reason: inspect(reason)}
          )

          config
      end
    end
  end

  defp fetch_runtime_bot_identity(config) do
    case SlackOpenAPI.post(client(config), "auth.test", body: %{}) do
      {:ok, %{"user_id" => user_id} = body} when is_binary(user_id) -> {:ok, body}
      {:ok, _body} -> {:error, :missing_bot_user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key), do: {:ok, key}

  defp token_fingerprint(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  defp token_prefix(value, prefix, key) do
    if String.starts_with?(value, prefix), do: :ok, else: {:error, {:invalid_token_prefix, key}}
  end

  defp optional_token_prefix(nil, _prefix, _key), do: :ok
  defp optional_token_prefix(value, prefix, key), do: token_prefix(value, prefix, key)

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

  defp maybe_map_put(map, _key, nil), do: map
  defp maybe_map_put(map, key, value), do: Map.put(map, key, value)
end
