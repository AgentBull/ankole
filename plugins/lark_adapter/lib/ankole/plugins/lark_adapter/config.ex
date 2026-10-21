defmodule Ankole.Plugins.LarkAdapter.Config do
  def platform_application(config),
    do: {:ok, "lark:" <> Torque.encode!(Tuple.to_list(connection_key(config)))}

  @moduledoc """
  Validation and runtime helpers for the first-party Lark / Feishu adapter.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias FeishuOpenAPI.Client

  import Ankole.Plugins.MapHelpers,
    only: [
      enum_string: 4,
      required_string: 2,
      optional_string: 3,
      optional_boolean: 3,
      integer_between: 5
    ]

  @binding_config_key_pattern ~r/\Asignals\.lark\.binding_configs\.[a-f0-9]{64}\z/
  @legacy_chat_key_pattern ~r/\Asignals\.lark\.bindings\.[A-Za-z0-9_.:-]+\z/
  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.lark\.[A-Za-z0-9_.:-]+\z/
  @domains ["feishu", "lark"]
  @default_oidc_scopes ["contact:user.employee_id:readonly"]

  @type chat_config :: map()
  @type identity_config :: map()

  @doc """
  Exact AppConfigure definitions contributed by the plugin.
  """
  @spec app_config_definitions() :: []
  def app_config_definitions, do: []

  @doc """
  AppConfigure key patterns contributed by the plugin.
  """
  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals.lark.binding_configs.*",
        key_pattern: @binding_config_key_pattern,
        encrypted: true,
        console_writable: false,
        scope: :global,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted binding-owned Lark / Feishu chat configuration."
      ),
      AppConfigure.define_pattern(
        id: "signals.lark.bindings.*",
        key_pattern: @legacy_chat_key_pattern,
        encrypted: true,
        console_writable: false,
        scope: :global,
        schema: Schema.new(&validate_chat_config/1),
        description: "Encrypted legacy Lark / Feishu chat binding configuration."
      ),
      AppConfigure.define_pattern(
        id: "principals.identity_providers.lark.*",
        scope: :tenant,
        console_writable: false,
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted Lark / Feishu identity-provider configuration."
      )
    ]
  end

  @doc """
  Builds the stable AppConfigure key owned by one Agent binding.

  The digest keeps arbitrary Agent and binding names outside the AppConfigure
  key grammar while the binding row remains the authoritative reverse mapping.
  The separate `binding_configs` root cannot overlap a legacy Agent UID key.
  """
  @spec binding_config_key(String.t(), String.t()) :: String.t()
  def binding_config_key(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    Ankole.Signals.Bindings.binding_config_key(
      "signals.lark.binding_configs",
      agent_uid,
      binding_name
    )
  end

  @doc """
  Normalizes and validates chat binding configuration loaded from AppConfigure.
  """
  @spec validate_chat_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_chat_config(value) when is_map(value) do
    with {:ok, app_id} <- required_string(value, "appID"),
         {:ok, app_secret} <- required_string(value, "appSecret"),
         {:ok, domain} <- enum_string(value, "domain", @domains, "feishu"),
         {:ok, identity_provider} <- optional_string(value, "identityProvider", nil),
         {:ok, user_name} <- optional_string(value, "userName", "Lark / Feishu") do
      {:ok,
       %{
         "appID" => app_id,
         "appSecret" => app_secret,
         "domain" => domain,
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
      "lark",
      Map.get(config, "identityProvider"),
      "lark-main"
    )
  end

  @doc """
  Validates chat config when it is used as a Signal Binding.

  A binding needs no extra input beyond the chat config: the connection owner
  resolves the bot's own `open_id` through
  `Ankole.Plugins.LarkAdapter.BotIdentity` when it starts, so operators are
  never asked to supply a bot identity by hand.
  """
  @spec validate_binding_config(term()) :: {:ok, chat_config()} | {:error, term()}
  def validate_binding_config(value), do: validate_chat_config(value)

  @doc """
  Normalizes and validates identity-provider configuration loaded from AppConfigure.
  """
  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    with {:ok, app_id} <- required_string(value, "appID"),
         {:ok, app_secret} <- required_string(value, "appSecret"),
         {:ok, domain} <- enum_string(value, "domain", @domains, "feishu"),
         oidc <- MapHelpers.fetch_map(value, "oidc", %{}),
         sync <- MapHelpers.fetch_map(value, "sync", %{}),
         {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, oidc_scopes} <- string_array(oidc, "scopes", @default_oidc_scopes),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         {:ok, sync_websocket} <- optional_boolean(sync, "websocket", true),
         {:ok, sync_page_size} <- integer_between(sync, "pageSize", 50, 1, 50),
         {:ok, admission_scope} <-
           enum_string(sync, "admissionScope", ["none", "contact"], "none"),
         {:ok, removal_percent} <- integer_between(sync, "maximumRemovalPercent", 20, 1, 100) do
      sync_websocket = sync_websocket and sync_contacts

      {:ok,
       %{
         "appID" => app_id,
         "appSecret" => app_secret,
         "domain" => domain,
         "oidc" => %{"enabled" => oidc_enabled, "scopes" => oidc_scopes},
         "sync" => %{
           "contacts" => sync_contacts,
           "websocket" => sync_websocket,
           "pageSize" => sync_page_size,
           "admissionScope" => admission_scope,
           "maximumRemovalPercent" => removal_percent
         }
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

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

  The optional application `:client_opts` value is an internal transport seam
  for tests and for the local fake platform in development. Stored binding
  config cannot override the provider endpoint.
  """
  @spec client(chat_config() | identity_config(), keyword()) :: Client.t()
  def client(config, opts \\ []) when is_map(config) do
    client_opts =
      :ankole
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:client_opts, [])

    Client.new(
      Map.fetch!(config, "appID"),
      fn -> Map.fetch!(config, "appSecret") end,
      [domain: domain_atom(Map.fetch!(config, "domain"))]
      |> Keyword.merge(client_opts)
      |> Keyword.merge(opts)
    )
  end

  @doc """
  Returns the stable local connection key for config that shares one Lark app.
  """
  @spec connection_key(chat_config() | identity_config()) :: {String.t(), String.t()}
  def connection_key(config), do: {Map.fetch!(config, "domain"), Map.fetch!(config, "appID")}

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
  Returns the provider base URL for the configured Lark product region.
  """
  @spec domain_base_url(String.t()) :: String.t()
  def domain_base_url("feishu"), do: Client.base_url_for(:feishu)
  def domain_base_url("lark"), do: Client.base_url_for(:lark)

  # Converts stored string config into the atom expected by FeishuOpenAPI.
  #
  @spec domain_atom(String.t()) :: :feishu | :lark
  defp domain_atom("feishu"), do: :feishu
  defp domain_atom("lark"), do: :lark

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
