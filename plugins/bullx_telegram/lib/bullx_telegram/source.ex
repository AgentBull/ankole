defmodule BullxTelegram.Source do
  @moduledoc """
  Runtime representation of one configured Telegram Gateway source.

  The struct keeps secrets out of `Inspect` and resolves the bot token from
  encrypted plugin credentials. The persisted source config carries no token.
  """

  alias BullX.Gateway.SourceConfig
  alias BullxTelegram.Error

  @default_dedupe_ttl_ms 300_000
  @default_poll_timeout_s 30
  @default_poll_limit 100
  @default_poll_retry_max 10
  @default_flood_wait_max_ms 5_000
  @default_stream_update_interval_ms 1_000
  @default_stream_chunk_soft_limit 3_900
  @default_message_context_ttl_seconds 2_592_000
  @default_direct_command_dedupe_ttl_seconds 300

  @derive {Inspect, except: [:bot_token]}
  defstruct [
    :source_config,
    :adapter,
    :channel_id,
    :credential_id,
    :bot_token,
    :bot_username,
    :bot_id,
    web_login_disabled: false,
    poll_timeout_s: @default_poll_timeout_s,
    poll_limit: @default_poll_limit,
    poll_retry_max: @default_poll_retry_max,
    flood_wait_max_ms: @default_flood_wait_max_ms,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    stream_chunk_soft_limit: @default_stream_chunk_soft_limit,
    direct_command_dedupe_ttl_seconds: @default_direct_command_dedupe_ttl_seconds,
    message_context_ttl_seconds: @default_message_context_ttl_seconds,
    dedupe_ttl_ms: @default_dedupe_ttl_ms,
    attention: %{
      "allowed_chat_ids" => [],
      "ignored_chat_ids" => [],
      "ignored_thread_ids" => [],
      "require_mention" => true,
      "free_response_chat_ids" => []
    },
    commands: %{"sync_policy" => "replace"},
    api_module: Telegram.Api,
    start_transport?: true
  ]

  @type t :: %__MODULE__{}

  @spec normalize(SourceConfig.t() | map()) :: {:ok, t()} | {:error, map()}
  def normalize(%SourceConfig{} = source) do
    with :ok <- ensure_telegram(source.adapter),
         {:ok, config} <- stringify_keys(source.config),
         {:ok, credential_id} <- optional_string(config, "credential_id", "default"),
         {:ok, credential} <- credential(credential_id),
         {:ok, attention} <- normalize_attention(Map.get(config, "attention", %{})),
         {:ok, commands} <- normalize_commands(Map.get(config, "commands", %{})) do
      bot_username =
        present_string(Map.get(config, "bot_username")) ||
          Map.get(credential, "bot_username")

      {:ok,
       %__MODULE__{
         source_config: source,
         adapter: "telegram",
         channel_id: source.channel_id,
         credential_id: credential_id,
         bot_token: Map.fetch!(credential, "bot_token"),
         bot_username: bot_username,
         web_login_disabled: optional_boolean(config, "web_login_disabled", false),
         poll_timeout_s:
           positive_integer(config, "poll_timeout_s", @default_poll_timeout_s),
         poll_limit:
           bounded_integer(
             config,
             "poll_limit",
             @default_poll_limit,
             1,
             100
           ),
         poll_retry_max:
           non_negative_integer(config, "poll_retry_max", @default_poll_retry_max),
         flood_wait_max_ms:
           non_negative_integer(config, "flood_wait_max_ms", @default_flood_wait_max_ms),
         stream_update_interval_ms:
           positive_integer(
             config,
             "stream_update_interval_ms",
             @default_stream_update_interval_ms
           ),
         stream_chunk_soft_limit:
           positive_integer(
             config,
             "stream_chunk_soft_limit",
             @default_stream_chunk_soft_limit
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
         dedupe_ttl_ms:
           non_negative_integer(config, "dedupe_ttl_ms", @default_dedupe_ttl_ms),
         attention: attention,
         commands: commands,
         api_module: api_module(config),
         start_transport?: optional_boolean(config, "start_transport", true)
       }}
    end
  end

  def normalize(%{} = source) do
    with {:ok, source} <- SourceConfig.normalize(source) do
      normalize(source)
    end
  end

  @spec public_config(SourceConfig.t() | map()) :: map()
  def public_config(%SourceConfig{} = source) do
    case stringify_keys(source.config) do
      {:ok, config} ->
        config
        |> Map.drop(["api_module"])
        |> Map.put_new("credential_id", Map.get(config, "credential_id", "default"))

      {:error, _reason} ->
        %{}
    end
  end

  def public_config(%{} = config) do
    config
    |> stringify_keys()
    |> case do
      {:ok, config} -> Map.drop(config, ["bot_token", "api_module"])
      {:error, _reason} -> %{}
    end
  end

  @spec request(t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(%__MODULE__{} = source, method, params \\ []) when is_binary(method) do
    source
    |> do_request(method, params)
    |> maybe_retry_after(source, method, params)
  end

  @spec web_login_allowed?(t()) :: boolean()
  def web_login_allowed?(%__MODULE__{web_login_disabled: disabled}), do: disabled != true

  defp do_request(%__MODULE__{} = source, method, params) do
    source.api_module.request(source.bot_token, method, params)
  end

  defp maybe_retry_after({:error, reason} = error, %__MODULE__{} = source, method, params) do
    case BullxTelegram.Error.retry_after_ms(reason) do
      ms when is_integer(ms) and ms <= source.flood_wait_max_ms ->
        Process.sleep(ms)
        do_request(source, method, params)

      _other ->
        error
    end
  end

  defp maybe_retry_after(result, _source, _method, _params), do: result

  defp ensure_telegram(adapter) when is_binary(adapter) do
    case String.downcase(adapter) do
      "telegram" -> :ok
      _other -> {:error, Error.config("source adapter must be telegram")}
    end
  end

  defp credential(credential_id) do
    case Map.fetch(BullxTelegram.Config.credentials!(), credential_id) do
      {:ok, credential} ->
        {:ok, credential}

      :error ->
        {:error,
         Error.config("missing Telegram credential profile", %{
           credential_id: credential_id
         })}
    end
  end

  defp normalize_attention(value) when is_map(value) do
    with {:ok, attention} <- stringify_keys(value) do
      normalized = %{
        "allowed_chat_ids" => string_list(attention, "allowed_chat_ids"),
        "ignored_chat_ids" => string_list(attention, "ignored_chat_ids"),
        "ignored_thread_ids" => string_list(attention, "ignored_thread_ids"),
        "require_mention" => optional_boolean(attention, "require_mention", true),
        "free_response_chat_ids" => string_list(attention, "free_response_chat_ids")
      }

      {:ok, normalized}
    end
  end

  defp normalize_attention(_value),
    do: {:error, Error.config("Telegram attention config must be an object")}

  defp normalize_commands(value) when is_map(value) do
    with {:ok, commands} <- stringify_keys(value) do
      case Map.get(commands, "sync_policy", "replace") do
        policy when policy in ["replace", "off"] -> {:ok, %{"sync_policy" => policy}}
        _other -> {:error, Error.config("Telegram commands.sync_policy must be replace or off")}
      end
    end
  end

  defp normalize_commands(_value),
    do: {:error, Error.config("Telegram commands config must be an object")}

  defp api_module(config) do
    case Map.get(config, "api_module") do
      module when is_atom(module) -> module
      _value -> Telegram.Api
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
      _value -> {:error, Error.config("invalid Telegram source string", %{field: key})}
    end
  end

  defp optional_boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp string_list(map, key) do
    case Map.get(map, key, []) do
      values when is_list(values) ->
        values
        |> Enum.map(&stringify_id/1)
        |> Enum.reject(&is_nil/1)

      _value ->
        []
    end
  end

  defp stringify_id(value) when is_binary(value) and value != "", do: String.trim(value)
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(_value), do: nil

  defp positive_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp bounded_integer(map, key, default, min, max) do
    case positive_integer(map, key, default) do
      value when value >= min and value <= max -> value
      _value -> default
    end
  end

  defp non_negative_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil
end
