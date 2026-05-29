defmodule BullxTelegram.Source do
  @moduledoc """
  Runtime representation of one configured Telegram IMGateway source.

  The struct keeps bot tokens out of `Inspect`. Each source is one BullX
  channel instance backed by one Telegram bot token.
  """

  alias BullxTelegram.Error

  import BullX.Utils.Map,
    only: [
      reject_nil_values: 1,
      positive_integer: 3,
      bounded_integer: 5,
      non_negative_integer: 3,
      optional_boolean: 3,
      string_list: 3,
      stringify_id: 1,
      present_string: 1
    ]

  @default_poll_timeout_s 30
  @default_poll_limit 100
  @default_poll_retry_max 10
  @default_flood_wait_max_ms 5_000
  @default_stream_update_interval_ms 1_000
  @default_stream_chunk_soft_limit 3_900
  @default_message_context_ttl_seconds 2_592_000
  @default_direct_command_dedupe_ttl_seconds 90_000
  @default_group_message_mode :addressed_only
  @group_message_modes [:addressed_only, :observe_all, :engage_all]
  @default_trusted_realm_by_default false
  @telegram_message_hard_limit 4_096

  @derive {Inspect, except: [:bot_token]}
  defstruct [
    :id,
    :bot_token,
    :bot_username,
    :bot_id,
    :api_base,
    web_login_disabled?: false,
    poll_timeout_s: @default_poll_timeout_s,
    poll_limit: @default_poll_limit,
    poll_retry_max: @default_poll_retry_max,
    flood_wait_max_ms: @default_flood_wait_max_ms,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    stream_chunk_soft_limit: @default_stream_chunk_soft_limit,
    direct_command_dedupe_ttl_seconds: @default_direct_command_dedupe_ttl_seconds,
    message_context_ttl_seconds: @default_message_context_ttl_seconds,
    attention: %{
      "allowed_chat_ids" => [],
      "ignored_chat_ids" => [],
      "ignored_thread_ids" => [],
      "require_mention" => true,
      "free_response_chat_ids" => []
    },
    commands: %{"sync_policy" => "replace"},
    group_message_mode: @default_group_message_mode,
    trusted_realm_by_default: @default_trusted_realm_by_default,
    req_options: [],
    api_module: BullxTelegram.BotAPI,
    start_transport?: true
  ]

  @type t :: %__MODULE__{}

  @doc "Supported group message modes for transport admission and ambient handling."
  @spec group_message_modes() :: [atom()]
  def group_message_modes, do: @group_message_modes

  @spec normalize(t() | map()) :: {:ok, t()} | {:error, map()}
  def normalize(%__MODULE__{} = source), do: {:ok, source}

  def normalize(%{} = source) do
    with {:ok, config} <- stringify_keys(source),
         {:ok, id} <- optional_string(config, "id", map_value(config, "source")),
         {:ok, bot_token} <- optional_string(config, "bot_token", nil),
         {:ok, attention} <- normalize_attention(Map.get(config, "attention", %{})),
         {:ok, commands} <- normalize_commands(Map.get(config, "commands", %{})),
         {:ok, group_message_mode} <- group_message_mode(Map.get(config, "group_message_mode")),
         {:ok, req_options} <- optional_keyword(config, "req_options", []) do
      bot_id = bot_token |> String.split(":", parts: 2) |> List.first()

      {:ok,
       %__MODULE__{
         id: id,
         bot_token: bot_token,
         bot_username: present_string(Map.get(config, "bot_username")),
         bot_id: present_string(Map.get(config, "bot_id")) || bot_id,
         web_login_disabled?: optional_boolean(config, "web_login_disabled", false),
         poll_timeout_s: positive_integer(config, "poll_timeout_s", @default_poll_timeout_s),
         poll_limit: bounded_integer(config, "poll_limit", @default_poll_limit, 1, 100),
         poll_retry_max: non_negative_integer(config, "poll_retry_max", @default_poll_retry_max),
         flood_wait_max_ms:
           non_negative_integer(config, "flood_wait_max_ms", @default_flood_wait_max_ms),
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
             @telegram_message_hard_limit
           ),
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
         attention: attention,
         commands: commands,
         group_message_mode: group_message_mode,
         trusted_realm_by_default:
           optional_boolean(config, "trusted_realm_by_default", @default_trusted_realm_by_default),
         req_options: req_options,
         api_module: module_or(config, "api_module", BullxTelegram.BotAPI),
         api_base: present_string(Map.get(config, "api_base")),
         start_transport?: optional_boolean(config, "start_transport", true)
       }}
    end
  end

  @spec enabled_sources() :: {:ok, [t()]} | {:error, map()}
  def enabled_sources do
    BullX.IMGateway.ChannelAdapter.SourceRegistry.enabled_sources(
      &BullxTelegram.Config.im_gateway_sources!/0,
      &normalize/1
    )
  end

  @spec enabled_sources!() :: [t()]
  def enabled_sources! do
    BullX.IMGateway.ChannelAdapter.SourceRegistry.enabled_sources!(
      &BullxTelegram.Config.im_gateway_sources!/0,
      &normalize/1,
      "Telegram"
    )
  end

  @spec fetch_enabled_source(String.t()) :: {:ok, t()} | {:error, :not_found | map()}
  def fetch_enabled_source(source_id) when is_binary(source_id) do
    with {:ok, sources} <- enabled_sources() do
      BullX.IMGateway.ChannelAdapter.SourceRegistry.fetch_enabled_source(sources, source_id)
    end
  end

  def fetch_enabled_source(_source_id), do: {:error, :not_found}

  @spec public_config(t() | map()) :: map()
  def public_config(%__MODULE__{} = source) do
    %{
      "id" => source.id,
      "bot_id" => source.bot_id,
      "bot_username" => source.bot_username,
      "web_login_disabled" => source.web_login_disabled?,
      "attention" => source.attention,
      "commands" => source.commands,
      "group_message_mode" => Atom.to_string(source.group_message_mode),
      "trusted_realm_by_default" => source.trusted_realm_by_default,
      "start_transport" => source.start_transport?
    }
    |> reject_nil_values()
  end

  def public_config(%{} = config) do
    config
    |> stringify_keys()
    |> case do
      {:ok, config} -> Map.drop(config, ["bot_token", "req_options", "api_module"])
      {:error, _reason} -> %{}
    end
  end

  @spec request(t(), String.t(), keyword() | map()) :: {:ok, term()} | {:error, term()}
  def request(%__MODULE__{} = source, method, params \\ []) when is_binary(method) do
    source
    |> do_request(method, params)
    |> maybe_retry_after(source, method, params)
  end

  @spec connectivity_check(t() | map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source_config) do
    with {:ok, source} <- normalize(source_config),
         {:ok, bot} <- request(source, "getMe"),
         :ok <- verify_bot_username(source, bot) do
      {:ok,
       %{
         status: :ok,
         adapter: "telegram",
         source_id: source.id,
         capabilities: [:inbound, :send, :edit, :stream, :threads],
         details:
           %{
             "transport" => "polling",
             "bot_id" => stringify_id(Map.get(bot, "id")) || source.bot_id,
             "bot_username" => present_string(Map.get(bot, "username")) || source.bot_username,
             "credential" => "verified"
           }
           |> reject_nil_values()
       }}
    else
      {:error, %{} = error} -> {:error, Error.map(error)}
      {:error, reason} -> {:error, Error.map(reason)}
    end
  end

  defp do_request(%__MODULE__{} = source, method, params),
    do: source.api_module.request(source, method, params)

  defp maybe_retry_after({:error, reason} = error, %__MODULE__{} = source, method, params) do
    case Error.retry_after_ms(reason) do
      ms when is_integer(ms) and ms <= source.flood_wait_max_ms ->
        Process.sleep(ms)
        do_request(source, method, params)

      _value ->
        error
    end
  end

  defp maybe_retry_after(result, _source, _method, _params), do: result

  defp normalize_attention(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      {:ok,
       %{
         "allowed_chat_ids" => string_list(value, "allowed_chat_ids", []),
         "ignored_chat_ids" => string_list(value, "ignored_chat_ids", []),
         "ignored_thread_ids" => string_list(value, "ignored_thread_ids", []),
         "require_mention" => optional_boolean(value, "require_mention", true),
         "free_response_chat_ids" => string_list(value, "free_response_chat_ids", [])
       }}
    end
  end

  defp normalize_attention(_value),
    do: {:error, Error.config("Telegram attention config must be an object")}

  defp normalize_commands(value) when is_map(value) do
    with {:ok, value} <- stringify_keys(value) do
      case Map.get(value, "sync_policy", "replace") do
        policy when policy in ["replace", "off"] -> {:ok, %{"sync_policy" => policy}}
        _value -> {:error, Error.config("Telegram commands.sync_policy must be replace or off")}
      end
    end
  end

  defp normalize_commands(_value),
    do: {:error, Error.config("Telegram commands config must be an object")}

  defp group_message_mode(nil), do: {:ok, @default_group_message_mode}

  defp group_message_mode(value) when value in [:addressed_only, "addressed_only"],
    do: {:ok, :addressed_only}

  defp group_message_mode(value) when value in [:observe_all, "observe_all"],
    do: {:ok, :observe_all}

  defp group_message_mode(value) when value in [:engage_all, "engage_all"],
    do: {:ok, :engage_all}

  defp group_message_mode(_value),
    do:
      {:error,
       Error.config(
         "Telegram group_message_mode must be addressed_only, observe_all, or engage_all"
       )}

  defp verify_bot_username(%__MODULE__{bot_username: nil}, _bot), do: :ok

  defp verify_bot_username(%__MODULE__{bot_username: expected}, %{"username" => actual})
       when is_binary(actual) do
    case String.downcase(expected) == String.downcase(actual) do
      true ->
        :ok

      false ->
        {:error,
         Error.config("Telegram bot_username mismatch", %{expected: expected, actual: actual})}
    end
  end

  defp verify_bot_username(%__MODULE__{bot_username: expected}, _bot),
    do:
      {:error, Error.config("Telegram getMe response is missing username", %{expected: expected})}

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
      _value -> {:error, Error.config("invalid Telegram source string", %{field: key})}
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

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
