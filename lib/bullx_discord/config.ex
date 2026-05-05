defmodule BullXDiscord.Config do
  @moduledoc """
  Normalizes Discord adapter configuration at the Gateway boundary.

  Process-local Discord state is restartable. This struct keeps credentials
  redacted from inspection, records the per-channel Nostrum bot name, and
  exposes injectable API modules for tests.
  """

  @default_dedupe_ttl_ms :timer.minutes(5)
  @default_thread_ownership_cache_ttl_ms :timer.hours(24)
  @default_stream_update_interval_ms 1_000
  @default_stream_chunk_soft_limit 1_850
  @default_auto_archive_duration_minutes 1_440

  @derive {Inspect, except: [:bot_token, :client_secret]}
  defstruct [
    :channel,
    :channel_id,
    :application_id,
    :bot_token,
    :client_secret,
    :bot_user_id,
    :bot_name,
    dedupe_ttl_ms: @default_dedupe_ttl_ms,
    thread_ownership_cache_ttl_ms: @default_thread_ownership_cache_ttl_ms,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    stream_chunk_soft_limit: @default_stream_chunk_soft_limit,
    web_login_disabled: false,
    auto_thread: %{
      enabled: true,
      auto_archive_duration_minutes: @default_auto_archive_duration_minutes,
      no_thread_channel_ids: []
    },
    attention: %{
      allowed_channel_ids: [],
      ignored_channel_ids: [],
      require_mention: true
    },
    sso: %{scopes: ["identify", "email"]},
    application_commands: %{sync_policy: "safe"},
    req_options: [],
    gateway_module: BullXGateway,
    accounts_module: BullXAccounts,
    endpoint: BullXWeb.Endpoint,
    start_transport?: true,
    nostrum_bot_module: Nostrum.Bot,
    self_api: Nostrum.Api.Self,
    message_api: Nostrum.Api.Message,
    thread_api: Nostrum.Api.Thread,
    channel_api: Nostrum.Api.Channel,
    interaction_api: Nostrum.Api.Interaction,
    application_command_api: Nostrum.Api.ApplicationCommand
  ]

  @type t :: %__MODULE__{}

  @spec normalize(BullXGateway.Delivery.channel(), map() | t()) :: {:ok, t()} | {:error, map()}
  def normalize(channel, %__MODULE__{} = config) do
    %{
      config
      | channel: channel,
        channel_id: elem(channel, 1),
        bot_name: config.bot_name || default_bot_name(elem(channel, 1))
    }
    |> validate()
  end

  def normalize({:discord, channel_id} = channel, config)
      when is_binary(channel_id) and is_map(config) do
    resolved = resolve(config)

    cfg = %__MODULE__{
      channel: channel,
      channel_id: channel_id,
      application_id: present_string(value(resolved, :application_id)),
      bot_token: present_secret(value(resolved, :bot_token)),
      client_secret: present_secret(value(resolved, :client_secret)),
      bot_user_id: present_string(value(resolved, :bot_user_id)),
      bot_name: present_string(value(resolved, :bot_name)) || default_bot_name(channel_id),
      dedupe_ttl_ms: non_negative_integer(resolved, :dedupe_ttl_ms, @default_dedupe_ttl_ms),
      thread_ownership_cache_ttl_ms:
        non_negative_integer(
          resolved,
          :thread_ownership_cache_ttl_ms,
          @default_thread_ownership_cache_ttl_ms
        ),
      stream_update_interval_ms:
        non_negative_integer(
          resolved,
          :stream_update_interval_ms,
          @default_stream_update_interval_ms
        ),
      stream_chunk_soft_limit:
        positive_integer(resolved, :stream_chunk_soft_limit, @default_stream_chunk_soft_limit),
      web_login_disabled: boolean(value(resolved, :web_login_disabled, false), false),
      auto_thread: normalize_auto_thread(value(resolved, :auto_thread, %{})),
      attention: normalize_attention(value(resolved, :attention, %{})),
      sso: normalize_sso(value(resolved, :sso, %{})),
      application_commands:
        normalize_application_commands(value(resolved, :application_commands, %{})),
      req_options: value(resolved, :req_options, []),
      gateway_module: value(resolved, :gateway_module, BullXGateway),
      accounts_module: value(resolved, :accounts_module, BullXAccounts),
      endpoint: value(resolved, :endpoint, BullXWeb.Endpoint),
      start_transport?: value(resolved, :start_transport?, true),
      nostrum_bot_module: value(resolved, :nostrum_bot_module, Nostrum.Bot),
      self_api: value(resolved, :self_api, Nostrum.Api.Self),
      message_api: value(resolved, :message_api, Nostrum.Api.Message),
      thread_api: value(resolved, :thread_api, Nostrum.Api.Thread),
      channel_api: value(resolved, :channel_api, Nostrum.Api.Channel),
      interaction_api: value(resolved, :interaction_api, Nostrum.Api.Interaction),
      application_command_api:
        value(resolved, :application_command_api, Nostrum.Api.ApplicationCommand)
    }

    validate(cfg)
  end

  def normalize(channel, _config), do: {:error, payload_error("invalid Discord channel", channel)}

  @spec normalize!(BullXGateway.Delivery.channel(), map() | t()) :: t()
  def normalize!(channel, config) do
    case normalize(channel, config) do
      {:ok, cfg} -> cfg
      {:error, error} -> raise ArgumentError, "invalid Discord config: #{inspect(error)}"
    end
  end

  @spec web_login_allowed?(t()) :: boolean()
  def web_login_allowed?(%__MODULE__{web_login_disabled: disabled}), do: disabled != true

  @spec intents() :: [atom()]
  def intents, do: [:guilds, :guild_messages, :direct_messages, :message_content]

  @spec bot_options(t()) :: map()
  def bot_options(%__MODULE__{} = config) do
    %{
      name: config.bot_name,
      consumer: BullXDiscord.Consumer,
      intents: intents(),
      wrapped_token: fn -> secret_value(config.bot_token) end
    }
  end

  @spec redacted(t() | map()) :: map()
  def redacted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:bot_token, :client_secret])
  end

  def redacted(config) when is_map(config),
    do: config |> resolve() |> Map.drop([:bot_token, :client_secret])

  @spec with_bot(t(), (-> term())) :: term()
  def with_bot(%__MODULE__{bot_name: bot_name}, fun) when is_function(fun, 0) do
    Nostrum.Bot.with_bot(bot_name, fun)
  end

  @spec secret_value(String.t() | (-> String.t()) | nil) :: String.t() | nil
  def secret_value(fun) when is_function(fun, 0), do: fun.()
  def secret_value(value), do: value

  defp validate(%__MODULE__{application_id: nil}) do
    {:error, payload_error("Discord application_id is required", "application_id")}
  end

  defp validate(%__MODULE__{bot_token: nil}) do
    {:error, payload_error("Discord bot_token is required", "bot_token")}
  end

  defp validate(%__MODULE__{web_login_disabled: false, client_secret: nil}) do
    {:error, payload_error("Discord client_secret is required", "client_secret")}
  end

  defp validate(%__MODULE__{attention: %{require_mention: false}}) do
    {:error,
     payload_error("Discord free-response attention is not enabled", "attention.require_mention")}
  end

  defp validate(%__MODULE__{} = config), do: {:ok, config}

  defp normalize_auto_thread(value) when is_map(value) do
    value = resolve(value)

    %{
      enabled: boolean(value(value, :enabled, true), true),
      auto_archive_duration_minutes:
        positive_integer(
          value,
          :auto_archive_duration_minutes,
          @default_auto_archive_duration_minutes
        ),
      no_thread_channel_ids: string_list(value(value, :no_thread_channel_ids, []))
    }
  end

  defp normalize_auto_thread(_value), do: normalize_auto_thread(%{})

  defp normalize_attention(value) when is_map(value) do
    value = resolve(value)

    %{
      allowed_channel_ids: string_list(value(value, :allowed_channel_ids, [])),
      ignored_channel_ids: string_list(value(value, :ignored_channel_ids, [])),
      require_mention: boolean(value(value, :require_mention, true), true)
    }
  end

  defp normalize_attention(_value), do: normalize_attention(%{})

  defp normalize_sso(value) when is_map(value) do
    value = resolve(value)
    %{scopes: normalize_scopes(value(value, :scopes, ["identify", "email"]))}
  end

  defp normalize_sso(_value), do: %{scopes: ["identify", "email"]}

  defp normalize_application_commands(value) when is_map(value) do
    value = resolve(value)

    %{
      sync_policy:
        value(value, :sync_policy, "safe")
        |> to_string()
        |> String.trim()
        |> normalize_sync_policy()
    }
  end

  defp normalize_application_commands(_value), do: %{sync_policy: "safe"}

  defp normalize_sync_policy("off"), do: "off"
  defp normalize_sync_policy("safe"), do: "safe"
  defp normalize_sync_policy(_value), do: "safe"

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> ensure_required_scopes()
  end

  defp normalize_scopes(_scopes), do: ["identify", "email"]

  defp ensure_required_scopes(scopes) do
    ["identify", "email"]
    |> Enum.reduce(scopes, fn scope, acc ->
      case scope in acc do
        true -> acc
        false -> acc ++ [scope]
      end
    end)
  end

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

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp string_list(_values), do: []

  defp non_negative_integer(map, key, default),
    do: bounded_integer(value(map, key, default), default, 0)

  defp positive_integer(map, key, default),
    do: bounded_integer(value(map, key, default), default, 1)

  defp bounded_integer(value, _default, min) when is_integer(value) and value >= min, do: value

  defp bounded_integer(value, default, min) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> bounded_integer(parsed, default, min)
      _other -> default
    end
  end

  defp bounded_integer(_value, default, _min), do: default

  defp boolean(value, _default) when value in [true, false], do: value
  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean("1", _default), do: true
  defp boolean("0", _default), do: false
  defp boolean(_value, default), do: default

  defp default_bot_name(channel_id), do: "bullx-discord:#{channel_id}"

  defp payload_error(message, field) do
    %{"kind" => "payload", "message" => message, "details" => %{"field" => field}}
  end
end
