defmodule Discord.Source do
  @moduledoc """
  Runtime representation of one configured Discord Gateway source.

  Holds the normalized config plus the resolved bot credential. Bot tokens
  and OAuth2 client secrets are kept out of `Inspect` and never logged. The
  per-source Nostrum bot name is derived from the channel slug so per-bot
  REST calls can address the correct bot via `Nostrum.Bot.with_bot/2`.
  """

  alias BullX.Gateway.SourceConfig
  alias Discord.Error

  @default_direct_command_dedupe_ttl_seconds 300
  @default_message_context_ttl_seconds 2_592_000
  @default_thread_ownership_cache_ttl_seconds 86_400
  @default_stream_update_interval_ms 1_000
  @default_stream_chunk_soft_limit 1_850
  @default_auto_archive_duration_minutes 1_440
  @default_oauth2_scopes ["identify", "email"]
  @discord_message_hard_limit 2_000

  @derive {Inspect, except: [:bot_token, :client_secret]}
  defstruct [
    :source_config,
    :adapter,
    :channel_id,
    :credential_id,
    :application_id,
    :bot_token,
    :client_secret,
    :bot_user_id,
    :bot_name,
    direct_command_dedupe_ttl_seconds: @default_direct_command_dedupe_ttl_seconds,
    message_context_ttl_seconds: @default_message_context_ttl_seconds,
    thread_ownership_cache_ttl_seconds: @default_thread_ownership_cache_ttl_seconds,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    stream_chunk_soft_limit: @default_stream_chunk_soft_limit,
    auto_thread: %{
      "enabled" => true,
      "auto_archive_duration_minutes" => @default_auto_archive_duration_minutes,
      "no_thread_channel_ids" => []
    },
    attention: %{
      "allowed_channel_ids" => [],
      "ignored_channel_ids" => [],
      "ignored_thread_ids" => [],
      "require_mention" => true,
      "free_response_channel_ids" => []
    },
    oauth2: %{
      "enabled" => false,
      "redirect_uri" => nil,
      "scopes" => @default_oauth2_scopes
    },
    application_commands: %{"sync_policy" => "safe"},
    req_options: [],
    nostrum_bot_module: Nostrum.Bot,
    self_api: Nostrum.Api.Self,
    message_api: Nostrum.Api.Message,
    channel_api: Nostrum.Api.Channel,
    thread_api: Nostrum.Api.Thread,
    interaction_api: Nostrum.Api.Interaction,
    application_command_api: Nostrum.Api.ApplicationCommand,
    gateway_module: BullX.Gateway,
    accounts_module: BullX.Principals,
    endpoint: BullXWeb.Endpoint,
    start_transport?: true
  ]

  @type t :: %__MODULE__{}

  @spec normalize(SourceConfig.t() | map()) :: {:ok, t()} | {:error, map()}
  def normalize(%SourceConfig{} = source) do
    with :ok <- ensure_discord(source.adapter),
         {:ok, config} <- stringify_keys(source.config),
         {:ok, credential_id} <- optional_string(config, "credential_id", "default"),
         {:ok, credential} <- credential(credential_id),
         {:ok, attention} <- normalize_attention(Map.get(config, "attention", %{})),
         {:ok, auto_thread} <- normalize_auto_thread(Map.get(config, "auto_thread", %{})),
         {:ok, oauth2} <- normalize_oauth2(Map.get(config, "oauth2", %{}), credential),
         {:ok, application_commands} <-
           normalize_application_commands(Map.get(config, "application_commands", %{})) do
      bot_user_id = optional_present_string(config, "bot_user_id")

      {:ok,
       %__MODULE__{
         source_config: source,
         adapter: "discord",
         channel_id: source.channel_id,
         credential_id: credential_id,
         application_id: Map.fetch!(credential, "application_id"),
         bot_token: Map.fetch!(credential, "bot_token"),
         client_secret: Map.get(credential, "client_secret"),
         bot_user_id: bot_user_id,
         bot_name: bot_name(source.channel_id),
         direct_command_dedupe_ttl_seconds:
           positive_integer(
             config,
             "direct_command_dedupe_ttl_seconds",
             @default_direct_command_dedupe_ttl_seconds
           ),
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
         auto_thread: auto_thread,
         attention: attention,
         oauth2: oauth2,
         application_commands: application_commands,
         req_options: optional_keyword(config, "req_options", []),
         nostrum_bot_module: module_or(config, "nostrum_bot_module", Nostrum.Bot),
         self_api: module_or(config, "self_api", Nostrum.Api.Self),
         message_api: module_or(config, "message_api", Nostrum.Api.Message),
         channel_api: module_or(config, "channel_api", Nostrum.Api.Channel),
         thread_api: module_or(config, "thread_api", Nostrum.Api.Thread),
         interaction_api: module_or(config, "interaction_api", Nostrum.Api.Interaction),
         application_command_api:
           module_or(config, "application_command_api", Nostrum.Api.ApplicationCommand),
         gateway_module: module_or(config, "gateway_module", BullX.Gateway),
         accounts_module: module_or(config, "accounts_module", BullX.Principals),
         endpoint: module_or(config, "endpoint", BullXWeb.Endpoint),
         start_transport?: boolean_or(config, "start_transport", true)
       }}
    end
  end

  def normalize(%{} = source) do
    with {:ok, source} <- SourceConfig.normalize(source) do
      normalize(source)
    end
  end

  @spec public_config(SourceConfig.t() | map()) :: map()
  def public_config(%SourceConfig{} = source), do: public_config(source.config)

  def public_config(%{} = config) do
    case stringify_keys(config) do
      {:ok, config} ->
        config
        |> Map.drop([
          "bot_token",
          "client_secret",
          "nostrum_bot_module",
          "self_api",
          "message_api",
          "channel_api",
          "thread_api",
          "interaction_api",
          "application_command_api",
          "gateway_module",
          "accounts_module",
          "endpoint",
          "req_options",
          "start_transport"
        ])
        |> Map.put_new("credential_id", Map.get(config, "credential_id", "default"))

      {:error, _reason} ->
        %{}
    end
  end

  @spec oauth2_enabled?(t()) :: boolean()
  def oauth2_enabled?(%__MODULE__{oauth2: %{"enabled" => true}, client_secret: secret})
      when is_binary(secret) and secret != "",
      do: true

  def oauth2_enabled?(%__MODULE__{}), do: false

  @spec oauth2_scopes(t()) :: [String.t()]
  def oauth2_scopes(%__MODULE__{oauth2: %{"scopes" => scopes}})
      when is_list(scopes) and scopes != [],
      do: scopes

  def oauth2_scopes(%__MODULE__{}), do: @default_oauth2_scopes

  @spec oauth2_redirect_uri(t()) :: String.t() | nil
  def oauth2_redirect_uri(%__MODULE__{oauth2: %{"redirect_uri" => uri}})
      when is_binary(uri) and uri != "",
      do: uri

  def oauth2_redirect_uri(%__MODULE__{}), do: nil

  @doc """
  Wraps a function with Nostrum's per-bot context so REST calls target this
  source's bot. Tests inject a fake `nostrum_bot_module` that simply invokes
  the function.
  """
  @spec with_bot(t(), (-> term())) :: term()
  def with_bot(%__MODULE__{nostrum_bot_module: module, bot_name: bot_name}, fun)
      when is_function(fun, 0) do
    if function_exported?(module, :with_bot, 2) do
      module.with_bot(bot_name, fun)
    else
      fun.()
    end
  end

  @spec bot_options(t()) :: map()
  def bot_options(%__MODULE__{} = source) do
    %{
      name: source.bot_name,
      consumer: Discord.Consumer,
      intents: intents(),
      wrapped_token: fn -> secret_value(source.bot_token) end
    }
  end

  @spec intents() :: [atom()]
  def intents, do: [:guilds, :guild_messages, :direct_messages, :message_content]

  @spec secret_value(String.t() | (-> String.t()) | nil) :: String.t() | nil
  def secret_value(fun) when is_function(fun, 0), do: fun.()
  def secret_value(value), do: value

  @spec bot_name(String.t()) :: atom()
  def bot_name(channel_id) when is_binary(channel_id) do
    String.to_atom("discord:" <> channel_id)
  end

  defp ensure_discord(adapter) when is_binary(adapter) do
    case String.downcase(adapter) do
      "discord" -> :ok
      _other -> {:error, Error.config("source adapter must be discord")}
    end
  end

  defp credential(credential_id) do
    case Map.fetch(Discord.Config.credentials!(), credential_id) do
      {:ok, credential} ->
        {:ok, credential}

      :error ->
        {:error,
         Error.config("missing Discord credential profile", %{credential_id: credential_id})}
    end
  end

  defp normalize_attention(value) when is_map(value) do
    with {:ok, attention} <- stringify_keys(value) do
      normalized = %{
        "allowed_channel_ids" => string_list(attention, "allowed_channel_ids"),
        "ignored_channel_ids" => string_list(attention, "ignored_channel_ids"),
        "ignored_thread_ids" => string_list(attention, "ignored_thread_ids"),
        "require_mention" => boolean_or(attention, "require_mention", true),
        "free_response_channel_ids" => string_list(attention, "free_response_channel_ids")
      }

      {:ok, normalized}
    end
  end

  defp normalize_attention(_value),
    do: {:error, Error.config("Discord attention config must be an object")}

  defp normalize_auto_thread(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      normalized = %{
        "enabled" => boolean_or(value, "enabled", true),
        "auto_archive_duration_minutes" =>
          positive_integer(
            value,
            "auto_archive_duration_minutes",
            @default_auto_archive_duration_minutes
          ),
        "no_thread_channel_ids" => string_list(value, "no_thread_channel_ids")
      }

      {:ok, normalized}
    end
  end

  defp normalize_auto_thread(_value),
    do: {:error, Error.config("Discord auto_thread config must be an object")}

  defp normalize_oauth2(value, credential) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      enabled = boolean_or(value, "enabled", false)
      redirect_uri = optional_present_string(value, "redirect_uri")
      scopes = oauth2_scopes_value(value)

      cond do
        enabled and is_nil(Map.get(credential, "client_secret")) ->
          {:error,
           Error.config("Discord OAuth2 requires client_secret on the credential profile", %{
             "field" => "credentials.client_secret"
           })}

        enabled and is_nil(redirect_uri) ->
          {:error,
           Error.config("Discord OAuth2 requires redirect_uri", %{
             "field" => "oauth2.redirect_uri"
           })}

        true ->
          {:ok,
           %{
             "enabled" => enabled,
             "redirect_uri" => redirect_uri,
             "scopes" => scopes
           }}
      end
    end
  end

  defp normalize_oauth2(_value, _credential),
    do: {:error, Error.config("Discord oauth2 config must be an object")}

  defp normalize_application_commands(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      case Map.get(value, "sync_policy", "safe") do
        policy when policy in ["safe", "off"] ->
          {:ok, %{"sync_policy" => policy}}

        _other ->
          {:error, Error.config("Discord application_commands.sync_policy must be safe or off")}
      end
    end
  end

  defp normalize_application_commands(_value),
    do: {:error, Error.config("Discord application_commands config must be an object")}

  defp oauth2_scopes_value(value) do
    case Map.get(value, "scopes") do
      scopes when is_list(scopes) ->
        scopes
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> ensure_required_scopes()

      _other ->
        @default_oauth2_scopes
    end
  end

  defp ensure_required_scopes(scopes) do
    @default_oauth2_scopes
    |> Enum.reduce(scopes, fn scope, acc ->
      if scope in acc, do: acc, else: acc ++ [scope]
    end)
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

  defp stringify_value(%{} = value) do
    case stringify_keys(value) do
      {:ok, value} -> value
      {:error, _reason} -> value
    end
  end

  defp stringify_value([_ | _] = values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value([]), do: []
  defp stringify_value(value), do: value

  defp optional_string(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Error.config("invalid Discord source string", %{field: key})}
    end
  end

  defp optional_present_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp optional_keyword(map, key, default) do
    case Map.get(map, key, default) do
      [] -> []
      list when is_list(list) -> list
      _other -> default
    end
  end

  defp module_or(map, key, default) do
    case Map.get(map, key) do
      module when is_atom(module) and not is_nil(module) -> module
      _other -> default
    end
  end

  defp boolean_or(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp string_list(map, key) do
    case Map.get(map, key, []) do
      values when is_list(values) ->
        values
        |> Enum.map(&stringify_id/1)
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp stringify_id(value) when is_binary(value) and value != "", do: String.trim(value)
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(_value), do: nil

  defp positive_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp bounded_integer(map, key, default, min, max) do
    case positive_integer(map, key, default) do
      value when value >= min and value <= max -> value
      value when value > max -> max
      _other -> default
    end
  end
end
