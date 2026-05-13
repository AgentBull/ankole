defmodule Feishu.Source do
  @moduledoc """
  Runtime representation of one configured Feishu Gateway source.

  The struct keeps secrets out of `Inspect` and rebuilds the SDK client from
  encrypted plugin credentials plus source-local non-secret config.
  """

  alias BullX.Gateway.SourceConfig
  alias FeishuOpenAPI.Client

  @default_scopes ["openid", "profile", "email", "phone"]
  @default_message_context_ttl_seconds 2_592_000
  @default_card_action_dedupe_ttl_seconds 900
  @default_direct_command_dedupe_ttl_seconds 300
  @default_inline_media_max_bytes 524_288
  @default_stream_update_interval_ms 100

  @derive {Inspect, except: [:app_secret, :client]}
  defstruct [
    :source_config,
    :adapter,
    :channel_id,
    :credential_id,
    :app_id,
    :app_secret,
    :tenant_key,
    :bot_open_id,
    :client,
    domain: :feishu,
    oidc: %{"enabled" => false, "scopes" => @default_scopes},
    message_context_ttl_seconds: @default_message_context_ttl_seconds,
    card_action_dedupe_ttl_seconds: @default_card_action_dedupe_ttl_seconds,
    direct_command_dedupe_ttl_seconds: @default_direct_command_dedupe_ttl_seconds,
    inline_media_max_bytes: @default_inline_media_max_bytes,
    stream_update_interval_ms: @default_stream_update_interval_ms,
    req_options: [],
    headers: [],
    start_transport?: true
  ]

  @type t :: %__MODULE__{}

  @spec normalize(SourceConfig.t() | map()) :: {:ok, t()} | {:error, map()}
  def normalize(%SourceConfig{} = source) do
    with :ok <- ensure_feishu(source.adapter),
         {:ok, config} <- stringify_keys(source.config),
         {:ok, credential_id} <- optional_string(config, "credential_id", "default"),
         {:ok, credential} <- credential(credential_id),
         {:ok, domain} <- domain(Map.get(config, "domain", "feishu")),
         {:ok, oidc} <- oidc(Map.get(config, "oidc", %{})),
         {:ok, req_options} <- optional_keyword(config, "req_options", []),
         {:ok, headers} <- optional_list(config, "headers", []) do
      {:ok,
       %__MODULE__{
         source_config: source,
         adapter: "feishu",
         channel_id: source.channel_id,
         credential_id: credential_id,
         app_id: credential["app_id"],
         app_secret: credential["app_secret"],
         tenant_key: present_string(Map.get(config, "tenant_key")),
         bot_open_id: present_string(Map.get(config, "bot_open_id")),
         domain: domain,
         oidc: oidc,
         message_context_ttl_seconds:
           positive_integer(
             config,
             "message_context_ttl_seconds",
             @default_message_context_ttl_seconds
           ),
         card_action_dedupe_ttl_seconds:
           positive_integer(
             config,
             "card_action_dedupe_ttl_seconds",
             @default_card_action_dedupe_ttl_seconds
           ),
         direct_command_dedupe_ttl_seconds:
           positive_integer(
             config,
             "direct_command_dedupe_ttl_seconds",
             @default_direct_command_dedupe_ttl_seconds
           ),
         inline_media_max_bytes:
           non_negative_integer(config, "inline_media_max_bytes", @default_inline_media_max_bytes),
         stream_update_interval_ms:
           positive_integer(
             config,
             "stream_update_interval_ms",
             @default_stream_update_interval_ms
           ),
         req_options: req_options,
         headers: headers,
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
        |> Map.drop(["req_options", "headers"])
        |> Map.put_new("credential_id", Map.get(config, "credential_id", "default"))
        |> Map.put("domain", to_string(Map.get(config, "domain", "feishu")))

      {:error, _reason} ->
        %{}
    end
  end

  def public_config(%{} = config) do
    config
    |> stringify_keys()
    |> case do
      {:ok, config} -> Map.drop(config, ["app_secret", "headers", "req_options"])
      {:error, _reason} -> %{}
    end
  end

  @spec client!(t()) :: Client.t()
  def client!(%__MODULE__{client: %Client{} = client}), do: client

  def client!(%__MODULE__{} = source) do
    Client.new(source.app_id, fn -> source.app_secret end,
      domain: source.domain,
      req_options: source.req_options,
      headers: source.headers
    )
  end

  @spec oidc_enabled?(t()) :: boolean()
  def oidc_enabled?(%__MODULE__{oidc: %{"enabled" => true}}), do: true
  def oidc_enabled?(_source), do: false

  @spec oidc_redirect_uri(t()) :: String.t() | nil
  def oidc_redirect_uri(%__MODULE__{oidc: oidc}), do: Map.get(oidc, "redirect_uri")

  @spec oidc_scopes(t()) :: [String.t()]
  def oidc_scopes(%__MODULE__{oidc: oidc}), do: Map.get(oidc, "scopes", @default_scopes)

  defp ensure_feishu(adapter) when is_binary(adapter) do
    case String.downcase(adapter) do
      "feishu" -> :ok
      _other -> {:error, Feishu.Error.config("source adapter must be feishu")}
    end
  end

  defp credential(credential_id) do
    case Map.fetch(Feishu.Config.credentials!(), credential_id) do
      {:ok, credential} ->
        {:ok, credential}

      :error ->
        {:error,
         Feishu.Error.config("missing Feishu credential profile", %{credential_id: credential_id})}
    end
  end

  defp domain(value) when value in [:feishu, "feishu"], do: {:ok, :feishu}
  defp domain(value) when value in [:lark, "lark"], do: {:ok, :lark}
  defp domain(_value), do: {:error, Feishu.Error.config("Feishu domain must be feishu or lark")}

  defp oidc(value) when is_map(value) do
    with {:ok, oidc} <- stringify_keys(value),
         {:ok, enabled?} <- optional_boolean_result(oidc, "enabled", false),
         {:ok, scopes} <- optional_string_list(oidc, "scopes", @default_scopes),
         {:ok, redirect_uri} <- optional_nullable_string(oidc, "redirect_uri") do
      oidc =
        %{"enabled" => enabled?, "scopes" => scopes}
        |> maybe_put("redirect_uri", redirect_uri)

      {:ok, oidc}
    end
  end

  defp oidc(_value), do: {:error, Feishu.Error.config("Feishu oidc config must be an object")}

  defp stringify_keys(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), stringify_value(value))}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, key, stringify_value(value))}}

      _entry, _acc ->
        {:halt, {:error, Feishu.Error.config("source config keys must be strings or atoms")}}
    end)
  end

  defp stringify_keys(_value),
    do: {:error, Feishu.Error.config("source config must be an object")}

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
      _value -> {:error, Feishu.Error.config("invalid Feishu source string", %{field: key})}
    end
  end

  defp optional_nullable_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Feishu.Error.config("invalid Feishu source string", %{field: key})}
    end
  end

  defp optional_boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp optional_boolean_result(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, Feishu.Error.config("invalid Feishu source boolean", %{field: key})}
    end
  end

  defp optional_string_list(map, key, default) do
    case Map.get(map, key, default) do
      values when is_list(values) ->
        values
        |> Enum.map(&present_string/1)
        |> Enum.reject(&is_nil/1)
        |> case do
          [_ | _] = values -> {:ok, values}
          [] -> {:error, Feishu.Error.config("invalid Feishu source string list", %{field: key})}
        end

      _value ->
        {:error, Feishu.Error.config("invalid Feishu source string list", %{field: key})}
    end
  end

  defp optional_keyword(map, key, default) do
    case Map.get(map, key, default) do
      value when is_list(value) ->
        {:ok, value}

      _value ->
        {:error, Feishu.Error.config("invalid Feishu source keyword option", %{field: key})}
    end
  end

  defp optional_list(map, key, default) do
    case Map.get(map, key, default) do
      value when is_list(value) -> {:ok, value}
      _value -> {:error, Feishu.Error.config("invalid Feishu source list", %{field: key})}
    end
  end

  defp positive_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> value
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
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
