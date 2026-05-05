defmodule BullXFeishu.Config do
  @moduledoc """
  Normalizes Feishu channel configuration at the adapter boundary.

  The Gateway registry stores adapter specs as user-provided maps. This module
  resolves BullX's `{:system, "ENV"}` indirection, applies Feishu defaults, and
  builds the SDK client without logging secrets. BullX exposes only Feishu and
  Lark domains for self-built apps.
  """

  alias FeishuOpenAPI.Client

  @default_dedupe_ttl_ms :timer.minutes(5)
  @default_message_context_ttl_ms :timer.hours(24) * 30
  @default_card_action_dedupe_ttl_ms :timer.minutes(15)
  @default_inline_media_max_bytes 524_288
  @default_stream_update_interval_ms 100

  @derive {Inspect, except: [:app_secret, :client]}
  defstruct [
    :channel,
    :channel_id,
    :app_id,
    :app_secret,
    :bot_open_id,
    :bot_user_id,
    :client,
    web_login_disabled: false,
    domain: :feishu,
    dedupe_ttl_ms: @default_dedupe_ttl_ms,
    message_context_ttl_ms: @default_message_context_ttl_ms,
    card_action_dedupe_ttl_ms: @default_card_action_dedupe_ttl_ms,
    inline_media_max_bytes: @default_inline_media_max_bytes,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    sso: %{scopes: ["openid", "profile", "email", "phone"]},
    req_options: [],
    headers: [],
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
        domain: normalize_domain(config.domain)
    }
    |> validate()
  end

  def normalize({:feishu, channel_id} = channel, config)
      when is_binary(channel_id) and is_map(config) do
    resolved = resolve(config)

    cfg = %__MODULE__{
      channel: channel,
      channel_id: channel_id,
      app_id: present_string(Map.get(resolved, :app_id)),
      app_secret: present_secret(Map.get(resolved, :app_secret)),
      web_login_disabled: boolean(Map.get(resolved, :web_login_disabled, false), false),
      domain: normalize_domain(Map.get(resolved, :domain, :feishu)),
      bot_open_id: present_string(Map.get(resolved, :bot_open_id)),
      bot_user_id: present_string(Map.get(resolved, :bot_user_id)),
      dedupe_ttl_ms: non_negative_integer(resolved, :dedupe_ttl_ms, @default_dedupe_ttl_ms),
      message_context_ttl_ms:
        non_negative_integer(resolved, :message_context_ttl_ms, @default_message_context_ttl_ms),
      card_action_dedupe_ttl_ms:
        non_negative_integer(
          resolved,
          :card_action_dedupe_ttl_ms,
          @default_card_action_dedupe_ttl_ms
        ),
      inline_media_max_bytes:
        non_negative_integer(resolved, :inline_media_max_bytes, @default_inline_media_max_bytes),
      stream_update_interval_ms:
        non_negative_integer(
          resolved,
          :stream_update_interval_ms,
          @default_stream_update_interval_ms
        ),
      sso: normalize_sso(Map.get(resolved, :sso, %{})),
      client: Map.get(resolved, :client),
      req_options: Map.get(resolved, :req_options, []),
      headers: Map.get(resolved, :headers, []),
      gateway_module: Map.get(resolved, :gateway_module, BullXGateway),
      accounts_module: Map.get(resolved, :accounts_module, BullXAccounts),
      endpoint: Map.get(resolved, :endpoint, BullXWeb.Endpoint),
      start_transport?: Map.get(resolved, :start_transport?, true)
    }

    validate(cfg)
  end

  def normalize(channel, _config), do: {:error, payload_error("invalid Feishu channel", channel)}

  @spec normalize!(BullXGateway.Delivery.channel(), map() | t()) :: t()
  def normalize!(channel, config) do
    case normalize(channel, config) do
      {:ok, cfg} -> cfg
      {:error, error} -> raise ArgumentError, "invalid Feishu config: #{inspect(error)}"
    end
  end

  @spec client!(t()) :: Client.t()
  def client!(%__MODULE__{client: %Client{} = client}), do: client

  def client!(%__MODULE__{} = config) do
    opts =
      [
        domain: config.domain,
        req_options: config.req_options,
        headers: config.headers
      ]

    Client.new(config.app_id, config.app_secret, opts)
  end

  @spec web_login_allowed?(t()) :: boolean()
  def web_login_allowed?(%__MODULE__{web_login_disabled: disabled}), do: disabled != true

  @spec redacted(t() | map()) :: map()
  def redacted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:app_secret, :client])
  end

  def redacted(config) when is_map(config), do: config |> resolve() |> Map.drop([:app_secret])

  defp validate(%__MODULE__{app_id: nil, client: nil}) do
    {:error, payload_error("Feishu app_id is required", "app_id")}
  end

  defp validate(%__MODULE__{app_secret: nil, client: nil}) do
    {:error, payload_error("Feishu app_secret is required", "app_secret")}
  end

  defp validate(%__MODULE__{} = config) do
    with :ok <- validate_domain(config.domain) do
      {:ok, config}
    end
  end

  defp validate_domain(domain) when domain in [:feishu, :lark], do: :ok

  defp validate_domain(_domain) do
    {:error, payload_error("Feishu domain must be :feishu or :lark", "domain")}
  end

  defp normalize_sso(nil), do: %{scopes: ["openid", "profile", "email", "phone"]}

  defp normalize_sso(sso) when is_map(sso) do
    sso = resolve(sso)

    %{
      scopes: normalize_scopes(Map.get(sso, :scopes, ["openid", "profile", "email", "phone"]))
    }
  end

  defp normalize_sso(_), do: %{scopes: ["openid", "profile", "email", "phone"]}

  defp resolve(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, resolve_value(value)} end)
  end

  defp resolve_value({:system, name}) when is_binary(name), do: System.get_env(name)

  defp resolve_value({:system, name, default}) when is_binary(name) do
    System.get_env(name) || default
  end

  defp resolve_value(%_{} = struct), do: struct
  defp resolve_value(map) when is_map(map), do: resolve(map)
  defp resolve_value(list) when is_list(list), do: Enum.map(list, &resolve_value/1)
  defp resolve_value(value), do: value

  defp present_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present_string(value), do: value

  defp present_secret(fun) when is_function(fun, 0), do: fun
  defp present_secret(value), do: present_string(value)

  defp normalize_domain(value) when value in [:feishu, :lark], do: value
  defp normalize_domain("feishu"), do: :feishu
  defp normalize_domain("lark"), do: :lark
  defp normalize_domain(value) when is_binary(value), do: String.trim(value)

  defp normalize_domain(value), do: value

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_scopes(_scopes), do: ["openid", "profile", "email", "phone"]

  defp non_negative_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp boolean(value, _default) when value in [true, false], do: value
  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean("1", _default), do: true
  defp boolean("0", _default), do: false
  defp boolean(_value, default), do: default

  defp payload_error(message, field) do
    %{"kind" => "payload", "message" => message, "details" => %{"field" => field}}
  end
end
