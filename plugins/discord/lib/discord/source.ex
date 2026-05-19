defmodule Discord.Source do
  @moduledoc """
  Runtime representation of one configured Discord EventBus source.

  The struct keeps bot tokens and OAuth2 client secrets out of `Inspect`.
  Durable source config stores only non-secret source metadata plus a
  `credential_id`; encrypted plugin credentials provide the provider secrets.
  """

  alias Discord.Error

  import BullX.Utils.Map,
    only: [
      maybe_put: 3,
      reject_nil_values: 1,
      positive_integer: 3,
      bounded_integer: 5,
      optional_boolean: 3,
      string_list: 3,
      stringify_id: 1,
      present_string: 1
    ]

  @default_oauth2_scopes ["identify", "email"]
  @default_message_context_ttl_seconds 2_592_000
  @default_thread_ownership_cache_ttl_seconds 86_400
  @default_stream_update_interval_ms 1_000
  @default_stream_chunk_soft_limit 1_850
  @default_auto_archive_duration_minutes 1_440
  @default_im_listen_mode :addressed_only
  @im_listen_modes [:addressed_only, :all_messages]
  @discord_message_hard_limit 2_000

  @derive {Inspect, except: [:bot_token, :client_secret]}
  defstruct [
    :id,
    :credential_id,
    :application_id,
    :bot_token,
    :client_secret,
    :bot_user_id,
    :connected_realm_ref,
    :api_base,
    oauth2: %{"enabled" => false, "redirect_uri" => nil, "scopes" => @default_oauth2_scopes},
    attention: %{
      "allowed_channel_ids" => [],
      "ignored_channel_ids" => [],
      "ignored_thread_ids" => [],
      "require_mention" => true,
      "free_response_channel_ids" => []
    },
    auto_thread: %{
      "enabled" => true,
      "auto_archive_duration_minutes" => @default_auto_archive_duration_minutes,
      "no_thread_channel_ids" => []
    },
    application_commands: %{"sync_policy" => "safe"},
    message_context_ttl_seconds: @default_message_context_ttl_seconds,
    thread_ownership_cache_ttl_seconds: @default_thread_ownership_cache_ttl_seconds,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    stream_chunk_soft_limit: @default_stream_chunk_soft_limit,
    im_listen_mode: @default_im_listen_mode,
    req_options: [],
    api_module: Discord.Rest,
    start_transport?: true,
    nostrum_bot_module: Nostrum.Bot
  ]

  @type t :: %__MODULE__{}

  @doc "Supported IM listen modes for transport admission."
  @spec im_listen_modes() :: [atom()]
  def im_listen_modes, do: @im_listen_modes

  @spec normalize(t() | map()) :: {:ok, t()} | {:error, map()}
  def normalize(%__MODULE__{} = source), do: {:ok, source}

  def normalize(%{} = source) do
    with {:ok, config} <- stringify_keys(source),
         {:ok, id} <- optional_string(config, "id", map_value(config, "source")),
         {:ok, credential_id} <- optional_string(config, "credential_id", "default"),
         {:ok, credential} <- credential(credential_id, config),
         {:ok, oauth2} <- normalize_oauth2(Map.get(config, "oauth2", %{}), credential),
         {:ok, attention} <- normalize_attention(Map.get(config, "attention", %{})),
         {:ok, auto_thread} <- normalize_auto_thread(Map.get(config, "auto_thread", %{})),
         {:ok, application_commands} <-
           normalize_application_commands(Map.get(config, "application_commands", %{})),
         {:ok, im_listen_mode} <- im_listen_mode(Map.get(config, "im_listen_mode")),
         {:ok, req_options} <- optional_keyword(config, "req_options", []) do
      application_id = Map.fetch!(credential, "application_id")

      {:ok,
       %__MODULE__{
         id: id,
         credential_id: credential_id,
         application_id: application_id,
         bot_token: Map.fetch!(credential, "bot_token"),
         client_secret: Map.get(credential, "client_secret"),
         bot_user_id: present_string(Map.get(config, "bot_user_id")),
         connected_realm_ref:
           present_string(Map.get(config, "connected_realm_ref")) ||
             "discord:application:" <> application_id,
         oauth2: oauth2,
         attention: attention,
         auto_thread: auto_thread,
         application_commands: application_commands,
         message_context_ttl_seconds:
           positive_integer(
             config,
             "message_context_ttl_seconds",
             @default_message_context_ttl_seconds
           ),
         thread_ownership_cache_ttl_seconds:
           positive_integer(
             config,
             "thread_ownership_cache_ttl_seconds",
             @default_thread_ownership_cache_ttl_seconds
           ),
         stream_update_interval_ms:
           positive_integer(
             config,
             "stream_update_interval_ms",
             @default_stream_update_interval_ms
           ),
         stream_chunk_soft_limit:
           bounded_integer(
             config,
             "stream_chunk_soft_limit",
             @default_stream_chunk_soft_limit,
             1,
             @discord_message_hard_limit
           ),
         im_listen_mode: im_listen_mode,
         req_options: req_options,
         api_module: module_or(config, "api_module", Discord.Rest),
         api_base: present_string(Map.get(config, "api_base")),
         start_transport?: optional_boolean(config, "start_transport", true),
         nostrum_bot_module: module_or(config, "nostrum_bot_module", Nostrum.Bot)
       }}
    end
  end

  @spec enabled_sources() :: {:ok, [t()]} | {:error, map()}
  def enabled_sources do
    BullX.EventBus.ChannelAdapter.SourceRegistry.enabled_sources(
      &Discord.Config.eventbus_sources!/0,
      &normalize/1
    )
  end

  @spec enabled_sources!() :: [t()]
  def enabled_sources! do
    BullX.EventBus.ChannelAdapter.SourceRegistry.enabled_sources!(
      &Discord.Config.eventbus_sources!/0,
      &normalize/1,
      "Discord"
    )
  end

  @spec fetch_enabled_source(String.t()) :: {:ok, t()} | {:error, :not_found | map()}
  def fetch_enabled_source(source_id) when is_binary(source_id) do
    with {:ok, sources} <- enabled_sources() do
      BullX.EventBus.ChannelAdapter.SourceRegistry.fetch_enabled_source(sources, source_id)
    end
  end

  def fetch_enabled_source(_source_id), do: {:error, :not_found}

  @spec public_config(t() | map()) :: map()
  def public_config(%__MODULE__{} = source) do
    %{
      "id" => source.id,
      "credential_id" => source.credential_id,
      "application_id" => source.application_id,
      "bot_user_id" => source.bot_user_id,
      "connected_realm_ref" => source.connected_realm_ref,
      "oauth2" => source.oauth2,
      "attention" => source.attention,
      "auto_thread" => source.auto_thread,
      "application_commands" => source.application_commands,
      "im_listen_mode" => Atom.to_string(source.im_listen_mode),
      "start_transport" => source.start_transport?
    }
    |> reject_nil_values()
  end

  def public_config(%{} = config) do
    config
    |> stringify_keys()
    |> case do
      {:ok, config} ->
        Map.drop(config, [
          "bot_token",
          "client_secret",
          "req_options",
          "api_module",
          "nostrum_bot_module"
        ])

      {:error, _reason} ->
        %{}
    end
  end

  @spec source_map(t()) :: map()
  def source_map(%__MODULE__{} = source), do: public_config(source)

  @spec request(t(), atom(), map() | keyword()) :: {:ok, term()} | {:error, term()}
  def request(%__MODULE__{} = source, operation, params \\ %{}) do
    source.api_module.request(source, operation, stringify_value(params))
  end

  @spec oauth2_enabled?(t()) :: boolean()
  def oauth2_enabled?(%__MODULE__{oauth2: %{"enabled" => true}, client_secret: secret})
      when is_binary(secret) and secret != "",
      do: true

  def oauth2_enabled?(_source), do: false

  @spec oauth2_redirect_uri(t()) :: String.t() | nil
  def oauth2_redirect_uri(%__MODULE__{oauth2: %{"redirect_uri" => uri}}) when is_binary(uri) and uri != "", do: uri
  def oauth2_redirect_uri(_source), do: nil

  @spec oauth2_scopes(t()) :: [String.t()]
  def oauth2_scopes(%__MODULE__{oauth2: %{"scopes" => scopes}}) when is_list(scopes) and scopes != [], do: scopes
  def oauth2_scopes(_source), do: @default_oauth2_scopes

  @spec bot_options(t()) :: map()
  def bot_options(%__MODULE__{} = source) do
    %{
      name: bot_name(source),
      consumer: Discord.Consumer,
      intents: [:guilds, :guild_messages, :direct_messages, :message_content],
      wrapped_token: fn -> source.bot_token end
    }
  end

  @spec bot_name(t()) :: atom()
  def bot_name(%__MODULE__{id: id}), do: String.to_atom("discord:" <> id)

  @spec connectivity_check(t() | map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source_config) do
    with {:ok, source} <- normalize(source_config),
         :ok <- ensure_oauth2_config(source),
         {:ok, bot} <- request(source, :get_current_bot),
         {:ok, application} <- request(source, :get_application),
         :ok <- verify_application(source, application) do
      {:ok,
       %{
         status: :ok,
         adapter: "discord",
         source_id: source.id,
         capabilities: [:inbound, :send, :edit, :stream, :threads, :application_commands, :oauth2],
         details:
           %{
             "transport" => "discord_gateway_ws",
             "application_id" => source.application_id,
             "bot_user_id" => stringify_id(Map.get(bot, "id")),
             "credential" => "verified",
             "message_content_intent_required" => true,
             "application_commands_sync_policy" => source.application_commands["sync_policy"],
             "connected_realm_ref" => source.connected_realm_ref
           }
           |> reject_nil_values()
       }}
    else
      {:error, %{} = error} -> {:error, Error.map(error)}
      {:error, reason} -> {:error, Error.map(reason)}
    end
  end

  defp credential(credential_id, config) do
    case direct_credential(config) do
      {:ok, credential} ->
        {:ok, credential}

      :error ->
        case Map.fetch(Discord.Config.credentials!(), credential_id) do
          {:ok, credential} ->
            {:ok, credential}

          :error ->
            {:error, Error.config("missing Discord credential profile", %{credential_id: credential_id})}
        end
    end
  end

  defp direct_credential(%{"application_id" => application_id, "bot_token" => bot_token} = config)
       when is_binary(application_id) and application_id != "" and is_binary(bot_token) and bot_token != "" do
    {:ok,
     %{"application_id" => application_id, "bot_token" => bot_token}
     |> maybe_put("client_secret", present_string(Map.get(config, "client_secret")))}
  end

  defp direct_credential(_config), do: :error

  defp normalize_oauth2(value, credential) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      enabled? = optional_boolean(value, "enabled", false)
      redirect_uri = present_string(Map.get(value, "redirect_uri"))
      scopes = string_list(value, "scopes", @default_oauth2_scopes)

      cond do
        enabled? and is_nil(present_string(Map.get(credential, "client_secret"))) ->
          {:error, Error.config("Discord OAuth2 requires client_secret")}

        enabled? and is_nil(redirect_uri) ->
          {:error, Error.config("Discord OAuth2 requires redirect_uri")}

        true ->
          {:ok, %{"enabled" => enabled?, "redirect_uri" => redirect_uri, "scopes" => ensure_oauth2_scopes(scopes)}}
      end
    end
  end

  defp normalize_oauth2(_value, _credential), do: {:error, Error.config("Discord oauth2 config must be an object")}

  defp normalize_attention(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      {:ok,
       %{
         "allowed_channel_ids" => string_list(value, "allowed_channel_ids", []),
         "ignored_channel_ids" => string_list(value, "ignored_channel_ids", []),
         "ignored_thread_ids" => string_list(value, "ignored_thread_ids", []),
         "require_mention" => optional_boolean(value, "require_mention", true),
         "free_response_channel_ids" => string_list(value, "free_response_channel_ids", [])
       }}
    end
  end

  defp normalize_attention(_value), do: {:error, Error.config("Discord attention config must be an object")}

  defp normalize_auto_thread(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      {:ok,
       %{
         "enabled" => optional_boolean(value, "enabled", true),
         "auto_archive_duration_minutes" =>
           positive_integer(value, "auto_archive_duration_minutes", @default_auto_archive_duration_minutes),
         "no_thread_channel_ids" => string_list(value, "no_thread_channel_ids", [])
       }}
    end
  end

  defp normalize_auto_thread(_value), do: {:error, Error.config("Discord auto_thread config must be an object")}

  defp normalize_application_commands(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      case Map.get(value, "sync_policy", "safe") do
        policy when policy in ["safe", "off"] -> {:ok, %{"sync_policy" => policy}}
        _value -> {:error, Error.config("Discord application_commands.sync_policy must be safe or off")}
      end
    end
  end

  defp normalize_application_commands(_value), do: {:error, Error.config("Discord application_commands config must be an object")}

  defp im_listen_mode(nil), do: {:ok, @default_im_listen_mode}
  defp im_listen_mode(value) when value in [:addressed_only, "addressed_only"], do: {:ok, :addressed_only}
  defp im_listen_mode(value) when value in [:all_messages, "all_messages"], do: {:ok, :all_messages}

  defp im_listen_mode(_value),
    do: {:error, Error.config("Discord im_listen_mode must be addressed_only or all_messages")}

  defp ensure_oauth2_config(%__MODULE__{} = source) do
    case source.oauth2["enabled"] == true and not oauth2_enabled?(source) do
      true -> {:error, Error.config("Discord OAuth2 requires client_secret")}
      false -> :ok
    end
  end

  defp verify_application(%__MODULE__{application_id: expected}, %{} = application) do
    case stringify_id(Map.get(application, "id")) do
      ^expected -> :ok
      nil -> :ok
      actual -> {:error, Error.config("Discord application id mismatch", %{expected: expected, actual: actual})}
    end
  end

  defp stringify_keys(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), stringify_value(value))}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, key, stringify_value(value))}}

      _entry, _acc ->
        {:halt, {:error, Error.config("source config keys must be strings or atoms")}}
    end)
  end

  defp stringify_keys(_value), do: {:error, Error.config("source config must be an object")}

  defp stringify_value(%{} = map) do
    case stringify_keys(map) do
      {:ok, value} -> value
      {:error, _reason} -> map
    end
  end

  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp optional_string(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Error.config("invalid Discord source string", %{field: key})}
    end
  end

  defp optional_keyword(map, key, default) do
    case Map.get(map, key, default) do
      [] -> {:ok, []}
      list when is_list(list) -> {:ok, list}
      _value -> {:ok, default}
    end
  end

  defp module_or(map, key, default) do
    case Map.get(map, key) do
      module when is_atom(module) and not is_nil(module) -> module
      _value -> default
    end
  end

  defp ensure_oauth2_scopes(scopes) do
    @default_oauth2_scopes
    |> Enum.reduce(scopes, fn scope, acc -> if scope in acc, do: acc, else: acc ++ [scope] end)
  end

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
