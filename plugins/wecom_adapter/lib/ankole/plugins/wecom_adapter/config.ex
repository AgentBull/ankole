defmodule Ankole.Plugins.WeComAdapter.Config do
  def platform_application(%{"botId" => _} = config),
    do: {:ok, "wecom-bot:" <> elem(connection_key(config), 1)}

  def platform_application(config),
    do:
      {:ok,
       "wecom-app:" <>
         Torque.encode!([Map.fetch!(config, "corpId"), Map.fetch!(config, "agentId")])}

  @moduledoc """
  Validation and runtime helpers for the first-party WeCom adapter.

  The chat face authenticates with an AI bot's `botId`/`secret` (the
  long-connection credential pair); the identity face authenticates with the
  corp's self-built app (`corpId`/`agentId`/`appSecret`) plus the optional
  contacts-sync secret. One agent gets at most one enabled WeCom binding, and
  one `botId` cannot be assigned to two agents.
  """

  alias Ankole.Signals.Bindings
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias WeComOpenAPI.Corp.Client, as: CorpClient

  import Ankole.Plugins.MapHelpers,
    only: [enum_string: 4, required_string: 2, optional_string: 3, optional_boolean: 3]

  @chat_key_pattern ~r/\Asignals\.wecom\.bindings\.[A-Za-z0-9_.:-]+\z/
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
        id: "signals.wecom.bindings.*",
        key_pattern: @chat_key_pattern,
        encrypted: true,
        console_writable: false,
        scope: :global,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted WeCom chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.wecom.*",
        scope: :tenant,
        console_writable: false,
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted WeCom identity-provider configuration."
      )
    ]
  end

  @doc "Normalizes and validates chat binding configuration loaded from AppConfigure."
  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, bot_id} <- required_string(value, "botId"),
         {:ok, secret} <- required_string(value, "secret"),
         {:ok, group_message_mode} <-
           enum_string(value, "group_message_mode", @group_message_modes, "addressed_only"),
         {:ok, identity_provider} <- optional_string(value, "identityProvider", nil),
         {:ok, user_name} <- optional_string(value, "userName", "企业微信 / WeCom") do
      {:ok,
       %{
         "botId" => bot_id,
         "secret" => secret,
         "group_message_mode" => group_message_mode,
         "identityProvider" => identity_provider,
         "userName" => user_name
       }}
    end
  end

  def validate_chat_config(_value), do: {:error, :invalid_chat_config}

  @doc """
  Returns the Principal subject namespace of one chat config. See
  `Ankole.Signals.SubjectNamespace.resolve/3`.
  """
  @spec subject_namespace(map()) :: String.t()
  def subject_namespace(config) do
    Ankole.Signals.SubjectNamespace.resolve(
      "wecom",
      Map.get(config, "identityProvider"),
      "wecom-main"
    )
  end

  @doc """
  Validates chat config when used as a Signal Binding. A binding needs
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
    with :ok <- ensure_single_enabled_binding(agent_uid, binding_name),
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

  defp ensure_single_enabled_binding(agent_uid, binding_name) do
    existing? =
      Ankole.Signals.list_bindings!(
        query: [
          filter: [
            agent_uid: agent_uid,
            adapter: "wecom",
            enabled: true,
            name: [not_eq: binding_name]
          ],
          limit: 1
        ]
      ) != []

    if existing?, do: {:error, :wecom_binding_already_exists}, else: :ok
  end

  defp ensure_bot_not_bound_to_another_agent(repo, agent_uid, bot_id) do
    Ankole.Signals.list_bindings!(
      query: [filter: [adapter: "wecom", enabled: true, agent_uid: [not_eq: agent_uid]]]
    )
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case Bindings.binding_config_in_tx(repo, binding, __MODULE__) do
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
end
