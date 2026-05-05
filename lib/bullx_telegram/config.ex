defmodule BullXTelegram.Config do
  @moduledoc """
  Normalizes Telegram adapter configuration at the Gateway boundary.

  The Telegram Bot API token is operator-supplied. The webhook secret is
  BullX-generated data; it is validated through `BullX.Config.GeneratedSecret`
  and redacted from runtime inspection.
  """

  alias BullX.Config.GeneratedSecret
  alias BullXTelegram.Error

  @default_dedupe_ttl_ms :timer.minutes(5)
  @default_poll_timeout_s 30
  @default_poll_limit 100
  @default_poll_retry_max 10
  @default_flood_wait_max_ms 5_000
  @default_stream_update_interval_ms 1_000
  @default_stream_chunk_soft_limit 3_900

  @derive {Inspect, except: [:bot_token, :transport]}
  defstruct [
    :channel,
    :channel_id,
    :bot_token,
    :bot_username,
    :bot_id,
    web_login_disabled: false,
    dedupe_ttl_ms: @default_dedupe_ttl_ms,
    poll_timeout_s: @default_poll_timeout_s,
    poll_limit: @default_poll_limit,
    poll_retry_max: @default_poll_retry_max,
    flood_wait_max_ms: @default_flood_wait_max_ms,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    stream_chunk_soft_limit: @default_stream_chunk_soft_limit,
    transport: %{mode: "polling", set_webhook: true, secret_token: nil},
    attention: %{
      allowed_chat_ids: [],
      ignored_chat_ids: [],
      ignored_thread_ids: [],
      require_mention: true,
      free_response_chat_ids: []
    },
    commands: %{sync_policy: "replace"},
    api_module: Telegram.Api,
    gateway_module: BullXGateway,
    accounts_module: BullXAccounts,
    endpoint: BullXWeb.Endpoint,
    start_transport?: true
  ]

  @type t :: %__MODULE__{}

  @spec normalize(BullXGateway.Delivery.channel(), map() | t()) :: {:ok, t()} | {:error, map()}
  def normalize(channel, %__MODULE__{} = config) do
    %{
      config
      | channel: channel,
        channel_id: elem(channel, 1),
        bot_username: normalize_bot_username(config.bot_username),
        transport: normalize_transport(config.transport),
        attention: normalize_attention(config.attention),
        commands: normalize_commands(config.commands)
    }
    |> validate()
  end

  def normalize({:telegram, channel_id} = channel, config)
      when is_binary(channel_id) and is_map(config) do
    resolved = resolve(config)

    cfg = %__MODULE__{
      channel: channel,
      channel_id: channel_id,
      bot_token: present_secret(value(resolved, :bot_token)),
      bot_username: normalize_bot_username(value(resolved, :bot_username)),
      bot_id: present_string(value(resolved, :bot_id)),
      web_login_disabled: boolean(value(resolved, :web_login_disabled, false), false),
      dedupe_ttl_ms: non_negative_integer(resolved, :dedupe_ttl_ms, @default_dedupe_ttl_ms),
      poll_timeout_s: positive_integer(resolved, :poll_timeout_s, @default_poll_timeout_s),
      poll_limit:
        bounded_integer(
          value(resolved, :poll_limit, @default_poll_limit),
          @default_poll_limit,
          1,
          100
        ),
      poll_retry_max: non_negative_integer(resolved, :poll_retry_max, @default_poll_retry_max),
      flood_wait_max_ms:
        non_negative_integer(resolved, :flood_wait_max_ms, @default_flood_wait_max_ms),
      stream_update_interval_ms:
        non_negative_integer(
          resolved,
          :stream_update_interval_ms,
          @default_stream_update_interval_ms
        ),
      stream_chunk_soft_limit:
        positive_integer(resolved, :stream_chunk_soft_limit, @default_stream_chunk_soft_limit),
      transport: normalize_transport(value(resolved, :transport, %{})),
      attention: normalize_attention(value(resolved, :attention, %{})),
      commands: normalize_commands(value(resolved, :commands, %{})),
      api_module: value(resolved, :api_module, Telegram.Api),
      gateway_module: value(resolved, :gateway_module, BullXGateway),
      accounts_module: value(resolved, :accounts_module, BullXAccounts),
      endpoint: value(resolved, :endpoint, BullXWeb.Endpoint),
      start_transport?: value(resolved, :start_transport?, true)
    }

    validate(cfg)
  end

  def normalize(channel, _config),
    do: {:error, Error.payload("invalid Telegram channel", %{field: channel})}

  @spec normalize!(BullXGateway.Delivery.channel(), map() | t()) :: t()
  def normalize!(channel, config) do
    case normalize(channel, config) do
      {:ok, cfg} -> cfg
      {:error, error} -> raise ArgumentError, "invalid Telegram config: #{inspect(error)}"
    end
  end

  @spec request(t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(%__MODULE__{} = config, method, params \\ []) when is_binary(method) do
    config
    |> do_request(method, params)
    |> maybe_retry_after(config, method, params)
  end

  @spec web_login_allowed?(t()) :: boolean()
  def web_login_allowed?(%__MODULE__{web_login_disabled: disabled}), do: disabled != true

  @spec webhook_url(t()) :: String.t()
  def webhook_url(%__MODULE__{endpoint: endpoint, channel_id: channel_id}) do
    endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/gateway/telegram/#{URI.encode(channel_id)}/webhook")
  end

  @spec validate_webhook_url(t()) :: :ok | {:error, map()}
  def validate_webhook_url(%__MODULE__{} = config) do
    config
    |> webhook_url()
    |> URI.parse()
    |> valid_webhook_uri?()
  end

  @spec secret_value(String.t() | (-> String.t()) | nil) :: String.t() | nil
  def secret_value(fun) when is_function(fun, 0), do: fun.()
  def secret_value(value), do: value

  @spec redacted(t() | map()) :: map()
  def redacted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:bot_token])
    |> Map.update!(:transport, &Map.put(&1, :secret_token, "[redacted]"))
  end

  def redacted(config) when is_map(config) do
    config
    |> resolve()
    |> Map.drop([:bot_token])
    |> Map.update(:transport, %{}, &Map.drop(&1, [:secret_token, "secret_token"]))
  end

  defp validate(%__MODULE__{} = config) do
    with :ok <- validate_channel_id(config.channel_id),
         :ok <- require_bot_token(config),
         :ok <- validate_transport(config.transport),
         :ok <- validate_secret_token(config),
         :ok <- validate_command_sync(config.commands) do
      {:ok, config}
    end
  end

  defp validate_channel_id(channel_id) do
    case safe_channel_id?(channel_id) do
      true ->
        :ok

      false ->
        {:error,
         Error.config("Telegram channel_id is not route-safe", %{"field" => "channel_id"})}
    end
  end

  defp require_bot_token(%__MODULE__{bot_token: nil}) do
    {:error, Error.payload("Telegram bot_token is required", %{"field" => "bot_token"})}
  end

  defp require_bot_token(%__MODULE__{}), do: :ok

  defp validate_transport(%{mode: mode}) when mode in ["polling", "webhook"], do: :ok

  defp validate_transport(_transport) do
    {:error,
     Error.config("Telegram transport mode must be polling or webhook", %{
       "field" => "transport.mode"
     })}
  end

  defp validate_secret_token(%__MODULE__{transport: %{secret_token: nil, mode: "webhook"}}) do
    {:error,
     Error.config("Telegram webhook secret_token is required", %{
       "field" => "transport.secret_token"
     })}
  end

  defp validate_secret_token(%__MODULE__{transport: %{secret_token: nil}}), do: :ok

  defp validate_secret_token(%__MODULE__{transport: %{secret_token: secret}}) do
    case GeneratedSecret.cast(secret) do
      {:ok, _secret} ->
        :ok

      :error ->
        {:error,
         Error.config("Telegram webhook secret_token must be generated by BullX", %{
           "field" => "transport.secret_token"
         })}
    end
  end

  defp validate_command_sync(%{sync_policy: policy}) when policy in ["replace", "off"], do: :ok

  defp validate_command_sync(_commands) do
    {:error,
     Error.config("Telegram command sync policy must be replace or off", %{
       "field" => "commands.sync_policy"
     })}
  end

  defp do_request(%__MODULE__{} = config, method, params) do
    config.api_module.request(secret_value(config.bot_token), method, params)
  end

  defp maybe_retry_after({:error, error}, config, method, params) do
    case Error.retry_after_ms(error) do
      milliseconds when is_integer(milliseconds) and milliseconds <= config.flood_wait_max_ms ->
        Process.sleep(milliseconds)
        do_request(config, method, params)

      _other ->
        {:error, error}
    end
  end

  defp maybe_retry_after(result, _config, _method, _params), do: result

  defp valid_webhook_uri?(%URI{scheme: "https", host: host}) when is_binary(host) and host != "",
    do: :ok

  defp valid_webhook_uri?(_uri) do
    {:error,
     Error.config("Telegram webhook URL must be absolute HTTPS", %{"field" => "endpoint.url"})}
  end

  defp normalize_transport(value) when is_map(value) do
    value = resolve(value)

    %{
      mode:
        value(value, :mode, "polling")
        |> to_string()
        |> String.trim()
        |> normalize_transport_mode(),
      set_webhook: boolean(value(value, :set_webhook, true), true),
      secret_token: present_string(value(value, :secret_token))
    }
  end

  defp normalize_transport(_value), do: normalize_transport(%{})

  defp normalize_transport_mode("webhook"), do: "webhook"
  defp normalize_transport_mode("polling"), do: "polling"
  defp normalize_transport_mode(_value), do: "polling"

  defp normalize_attention(value) when is_map(value) do
    value = resolve(value)

    %{
      allowed_chat_ids: string_list(value(value, :allowed_chat_ids, [])),
      ignored_chat_ids: string_list(value(value, :ignored_chat_ids, [])),
      ignored_thread_ids: string_list(value(value, :ignored_thread_ids, [])),
      require_mention: boolean(value(value, :require_mention, true), true),
      free_response_chat_ids: string_list(value(value, :free_response_chat_ids, []))
    }
  end

  defp normalize_attention(_value), do: normalize_attention(%{})

  defp normalize_commands(value) when is_map(value) do
    value = resolve(value)

    %{
      sync_policy:
        value(value, :sync_policy, "replace")
        |> to_string()
        |> String.trim()
        |> normalize_sync_policy()
    }
  end

  defp normalize_commands(_value), do: %{sync_policy: "replace"}

  defp normalize_sync_policy("off"), do: "off"
  defp normalize_sync_policy("replace"), do: "replace"
  defp normalize_sync_policy(_value), do: "replace"

  defp resolve(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, resolve_value(value)} end)
  end

  defp resolve_value({:system, name}) when is_binary(name), do: System.get_env(name)

  defp resolve_value({:system, name, default}) when is_binary(name),
    do: System.get_env(name) || default

  defp resolve_value(%_{} = struct), do: struct
  defp resolve_value(map) when is_map(map), do: resolve(map)
  defp resolve_value(list) when is_list(list), do: Enum.map(list, &resolve_value/1)
  defp resolve_value(value), do: value

  defp value(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp present_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present_string(value) when is_integer(value), do: Integer.to_string(value)
  defp present_string(value), do: value

  defp present_secret(fun) when is_function(fun, 0), do: fun
  defp present_secret(value), do: present_string(value)

  defp normalize_bot_username(nil), do: nil

  defp normalize_bot_username(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> case do
      "" -> nil
      username -> username
    end
  end

  defp normalize_bot_username(value), do: value |> to_string() |> normalize_bot_username()

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp string_list(values) when is_binary(values) do
    values
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_values), do: []

  defp non_negative_integer(map, key, default),
    do: bounded_integer(value(map, key, default), default, 0, :infinity)

  defp positive_integer(map, key, default),
    do: bounded_integer(value(map, key, default), default, 1, :infinity)

  defp bounded_integer(value, default, min, max) when is_integer(value) do
    case bounded?(value, min, max) do
      true -> value
      false -> default
    end
  end

  defp bounded_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> bounded_integer(parsed, default, min, max)
      _other -> default
    end
  end

  defp bounded_integer(_value, default, _min, _max), do: default

  defp bounded?(value, min, :infinity), do: value >= min
  defp bounded?(value, min, max), do: value >= min and value <= max

  defp boolean(value, _default) when value in [true, false], do: value
  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean("1", _default), do: true
  defp boolean("0", _default), do: false
  defp boolean(_value, default), do: default

  defp safe_channel_id?(channel_id) when is_binary(channel_id),
    do: channel_id != "" and not String.contains?(channel_id, "/")

  defp safe_channel_id?(_channel_id), do: false
end
