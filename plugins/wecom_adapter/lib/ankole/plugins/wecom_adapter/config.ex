defmodule Ankole.Plugins.WeComAdapter.Config do
  @moduledoc """
  Validation and runtime helpers for the first-party WeCom adapter.

  The chat face authenticates with an AI bot's `botId`/`secret` (the
  long-connection credential pair); the identity face authenticates with the
  corp's self-built app (`corpId`/`agentId`/`appSecret`) plus the optional
  contacts-sync secret. One agent gets at most one enabled WeCom binding, and
  one `botId` cannot be assigned to two agents.
  """

  import Ecto.Query, warn: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.Binding
  alias WeComOpenAPI.Corp.Client, as: CorpClient

  import Ankole.Plugins.MapHelpers,
    only: [required_string: 2, optional_string: 3, optional_boolean: 3]

  @chat_key_pattern ~r/\Asignals_gateway\.wecom\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.wecom\.[A-Za-z0-9_.:-]+\z/
  @group_message_modes ["addressed_only"]

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
        id: "signals_gateway.wecom.bindings.*",
        key_pattern: @chat_key_pattern,
        encrypted: true,
        console_writable: false,
        scope: :global,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted WeCom chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.wecom.*",
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted WeCom identity-provider configuration."
      )
    ]
  end

  @spec chat_config_key(String.t()) :: String.t()
  def chat_config_key(id), do: "signals_gateway.wecom.bindings.#{id}"

  @spec identity_config_key(String.t()) :: String.t()
  def identity_config_key(id), do: "principals.identity_providers.wecom.#{id}"

  @doc "Normalizes and validates chat binding configuration loaded from AppConfigure."
  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, bot_id} <- required_string(value, "botId"),
         {:ok, secret} <- required_string(value, "secret"),
         {:ok, group_message_mode} <-
           enum_string(value, "group_message_mode", @group_message_modes, "addressed_only"),
         {:ok, platform_subject_namespace} <-
           optional_string(value, "platformSubjectNamespace", "wecom-main"),
         {:ok, user_name} <- optional_string(value, "userName", "企业微信 / WeCom") do
      {:ok,
       %{
         "botId" => bot_id,
         "secret" => secret,
         "group_message_mode" => group_message_mode,
         "platformSubjectNamespace" => platform_subject_namespace,
         "userName" => user_name
       }}
    end
  end

  def validate_chat_config(_value), do: {:error, :invalid_chat_config}

  @doc """
  Validates chat config when used as a SignalsGateway binding. A binding needs
  no extra input beyond the chat config: the bot's own id arrives on every
  inbound frame (`aibotid`), so operators never supply a bot identity by hand.
  """
  @spec validate_binding_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_binding_config(value), do: validate_chat_config(value)

  @doc """
  Enforces the one-agent/one-bot assignment. Updating the current binding is
  allowed; disabled bindings do not reserve a bot.
  """
  @spec validate_binding_assignment(module(), String.t(), String.t(), chat_config()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(repo, agent_uid, binding_name, config)
      when is_atom(repo) and is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    with :ok <- ensure_single_enabled_binding(repo, agent_uid, binding_name),
         :ok <-
           ensure_bot_not_bound_to_another_agent(
             repo,
             agent_uid,
             Map.fetch!(config, "botId")
           ) do
      :ok
    end
  end

  @doc "Normalizes and validates identity-provider configuration loaded from AppConfigure."
  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    with {:ok, corp_id} <- required_string(value, "corpId"),
         {:ok, agent_id} <- required_string(value, "agentId"),
         {:ok, app_secret} <- required_string(value, "appSecret"),
         {:ok, contacts_secret} <- optional_string(value, "contactsSecret", nil),
         oidc <- MapHelpers.fetch_map(value, "oidc", %{}),
         sync <- MapHelpers.fetch_map(value, "sync", %{}),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         :ok <- ensure_sync_has_contacts_secret(sync_contacts, contacts_secret) do
      {:ok,
       %{
         "corpId" => corp_id,
         "agentId" => agent_id,
         "appSecret" => app_secret,
         "contactsSecret" => contacts_secret,
         "oidc" => %{"enabled" => oidc_enabled},
         "sync" => %{"contacts" => sync_contacts}
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

  # Directory sync without the contacts-sync secret would run as an empty or
  # nameless directory (2022-06 sensitive-field policy); reject at save time
  # instead of silently syncing nothing.
  defp ensure_sync_has_contacts_secret(false, _secret), do: :ok
  defp ensure_sync_has_contacts_secret(true, secret) when is_binary(secret), do: :ok
  defp ensure_sync_has_contacts_secret(true, _missing), do: {:error, :contacts_secret_required}

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

  @doc "Builds the corp REST client for the self-built app secret (login)."
  @spec app_client(identity_config()) :: CorpClient.t()
  def app_client(config) when is_map(config) do
    CorpClient.new(
      corp_id: Map.fetch!(config, "corpId"),
      secret: fn -> Map.fetch!(config, "appSecret") end
    )
  end

  @doc "Builds the corp REST client for the contacts-sync secret (directory)."
  @spec contacts_client(identity_config()) :: {:ok, CorpClient.t()} | {:error, term()}
  def contacts_client(config) when is_map(config) do
    case Map.get(config, "contactsSecret") do
      secret when is_binary(secret) ->
        {:ok,
         CorpClient.new(
           corp_id: Map.fetch!(config, "corpId"),
           secret: fn -> secret end
         )}

      _missing ->
        {:error, :contacts_secret_missing}
    end
  end

  @doc "Returns the stable local connection key for one bot."
  @spec connection_key(chat_config()) :: {String.t(), String.t()}
  def connection_key(config), do: {"wecom", Map.fetch!(config, "botId")}

  @doc "Fingerprints a secret for conflict detection without storing the secret in state."
  @spec secret_fingerprint(chat_config()) :: String.t()
  def secret_fingerprint(config) do
    :sha256
    |> :crypto.hash(Map.fetch!(config, "secret"))
    |> Base.encode16(case: :lower)
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key) when is_binary(key), do: {:ok, key}

  defp load_chat_config_ref_in_tx(repo, config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_global_by_key_in_tx(repo, key) do
      validate_chat_config(value)
    end
  end

  defp ensure_single_enabled_binding(repo, agent_uid, binding_name) do
    existing? =
      Binding
      |> where(
        [binding],
        binding.agent_uid == ^agent_uid and binding.adapter == "wecom" and
          binding.enabled == true and binding.name != ^binding_name
      )
      |> repo.exists?()

    if existing?, do: {:error, :wecom_binding_already_exists}, else: :ok
  end

  defp ensure_bot_not_bound_to_another_agent(repo, agent_uid, bot_id) do
    Binding
    |> where(
      [binding],
      binding.adapter == "wecom" and binding.enabled == true and
        binding.agent_uid != ^agent_uid
    )
    |> repo.all()
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case load_chat_config_ref_in_tx(repo, binding.config_ref) do
        {:ok, %{"botId" => ^bot_id}} ->
          {:halt, {:error, {:wecom_bot_already_bound, bot_id, binding.agent_uid}}}

        {:ok, %{"botId" => _other_bot_id}} ->
          {:cont, :ok}

        :error ->
          {:halt, {:error, {:wecom_binding_config_unavailable, binding.agent_uid, :missing}}}

        {:error, reason} ->
          {:halt, {:error, {:wecom_binding_config_unavailable, binding.agent_uid, reason}}}
      end
    end)
  end

  defp enum_string(map, key, values, default) do
    with {:ok, value} <- optional_string(map, key, default) do
      case value in values do
        true -> {:ok, value}
        false -> {:error, {:invalid_enum, key, values}}
      end
    end
  end

end
