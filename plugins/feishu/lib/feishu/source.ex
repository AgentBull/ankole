defmodule Feishu.Source do
  @moduledoc """
  Runtime representation of one configured Feishu EventBus source.

  The struct keeps secrets out of `Inspect` and rebuilds the SDK client from
  encrypted plugin credentials plus source-local non-secret config.
  """

  alias FeishuOpenAPI.{Auth, Client}

  @default_scopes ["openid", "profile", "email", "phone"]
  @default_message_context_ttl_seconds 2_592_000
  @default_card_action_dedupe_ttl_seconds 900
  @default_direct_command_dedupe_ttl_seconds 300
  @default_inline_media_max_bytes 524_288
  @default_stream_update_interval_ms 100

  @derive {Inspect, except: [:app_secret, :verification_token, :encrypt_key, :client]}
  defstruct [
    :id,
    :credential_id,
    :app_id,
    :app_secret,
    :tenant_key,
    :bot_open_id,
    :bot_user_id,
    :verification_token,
    :encrypt_key,
    :connected_realm_ref,
    :client,
    app_type: :self_built,
    domain: :feishu,
    oidc: %{"enabled" => false, "scopes" => @default_scopes},
    web_login_disabled?: false,
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

  @spec normalize(t() | map()) :: {:ok, t()} | {:error, map()}
  def normalize(%__MODULE__{} = source), do: {:ok, source}

  def normalize(%{} = source) do
    with {:ok, config} <- stringify_keys(source),
         {:ok, id} <- optional_string(config, "id", map_value(config, "source")),
         {:ok, credential_id} <- optional_string(config, "credential_id", "default"),
         {:ok, credential} <- credential(credential_id, config),
         {:ok, domain} <- domain(Map.get(config, "domain", "feishu")),
         {:ok, app_type} <- app_type(Map.get(credential, "app_type", "self_built")),
         {:ok, oidc} <- oidc(Map.get(config, "oidc", %{})),
         {:ok, req_options} <- optional_keyword(config, "req_options", []),
         {:ok, headers} <- optional_list(config, "headers", []) do
      {:ok,
       %__MODULE__{
         id: id,
         credential_id: credential_id,
         app_id: credential["app_id"],
         app_secret: credential["app_secret"],
         app_type: app_type,
         tenant_key: present_string(Map.get(config, "tenant_key")),
         bot_open_id: present_string(Map.get(config, "bot_open_id")),
         bot_user_id: present_string(Map.get(config, "bot_user_id")),
         verification_token: present_string(credential["verification_token"]),
         encrypt_key: present_string(credential["encrypt_key"]),
         connected_realm_ref: present_string(Map.get(config, "connected_realm_ref")),
         domain: domain,
         oidc: oidc,
         web_login_disabled?: optional_boolean(config, "web_login_disabled", false),
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

  @spec enabled_sources() :: {:ok, [t()]} | {:error, map()}
  def enabled_sources do
    Feishu.Config.eventbus_sources!()
    |> Enum.filter(&(Map.get(&1, "enabled", true) == true))
    |> Enum.reduce_while({:ok, []}, fn config, {:ok, acc} ->
      case normalize(config) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      {:error, _error} = error -> error
    end
  end

  @spec enabled_sources!() :: [t()]
  def enabled_sources! do
    case enabled_sources() do
      {:ok, sources} -> sources
      {:error, error} -> raise ArgumentError, "invalid Feishu source config: #{inspect(error)}"
    end
  end

  @spec fetch_enabled_source(String.t()) :: {:ok, t()} | {:error, :not_found | map()}
  def fetch_enabled_source(source_id) when is_binary(source_id) do
    with {:ok, sources} <- enabled_sources() do
      case Enum.find(sources, &(&1.id == source_id)) do
        nil -> {:error, :not_found}
        source -> {:ok, source}
      end
    end
  end

  def fetch_enabled_source(_source_id), do: {:error, :not_found}

  @spec public_config(t() | map()) :: map()
  def public_config(%__MODULE__{} = source) do
    %{
      "id" => source.id,
      "credential_id" => source.credential_id,
      "domain" => Atom.to_string(source.domain),
      "connected_realm_ref" => source.connected_realm_ref,
      "tenant_key" => source.tenant_key,
      "bot_open_id" => source.bot_open_id,
      "bot_user_id" => source.bot_user_id,
      "oidc" => source.oidc,
      "web_login_disabled" => source.web_login_disabled?,
      "start_transport" => source.start_transport?
    }
    |> reject_nil_values()
  end

  def public_config(%{} = config) do
    config
    |> stringify_keys()
    |> case do
      {:ok, config} -> Map.drop(config, ["app_id", "app_secret", "headers", "req_options"])
      {:error, _reason} -> %{}
    end
  end

  @spec source_map(t()) :: map()
  def source_map(%__MODULE__{} = source), do: public_config(source)

  @spec client!(t()) :: Client.t()
  def client!(%__MODULE__{client: %Client{} = client}), do: client

  def client!(%__MODULE__{} = source) do
    Client.new(source.app_id, fn -> source.app_secret end,
      app_type: source.app_type,
      domain: source.domain,
      req_options: source.req_options,
      headers: source.headers
    )
  end

  @spec oidc_enabled?(t()) :: boolean()
  def oidc_enabled?(%__MODULE__{oidc: %{"enabled" => true}, web_login_disabled?: false}),
    do: true

  def oidc_enabled?(_source), do: false

  @spec web_login_enabled?(t()) :: boolean()
  def web_login_enabled?(%__MODULE__{web_login_disabled?: false}), do: true
  def web_login_enabled?(_source), do: false

  @spec card_action_verify_config(t()) :: {:ok, map()} | {:error, map()}
  def card_action_verify_config(%__MODULE__{} = source) do
    case present_string(source.verification_token) do
      token when is_binary(token) ->
        {:ok,
         %{
           verification_token: token,
           encrypt_key: present_string(source.encrypt_key)
         }}

      nil ->
        {:error, Feishu.Error.config("Feishu card-action verification_token is required")}
    end
  end

  @spec oidc_redirect_uri(t()) :: String.t() | nil
  def oidc_redirect_uri(%__MODULE__{oidc: oidc}), do: Map.get(oidc, "redirect_uri")

  @spec oidc_scopes(t()) :: [String.t()]
  def oidc_scopes(%__MODULE__{oidc: oidc}), do: Map.get(oidc, "scopes", @default_scopes)

  @spec connectivity_check(t() | map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source_config) do
    with {:ok, source} <- normalize(source_config),
         {:ok, token} <- Auth.tenant_access_token(client!(source)) do
      {:ok,
       %{
         status: :ok,
         adapter: "feishu",
         source_id: source.id,
         capabilities: [:inbound, :send, :edit, :stream, :cards, :oidc],
         details:
           %{
             "domain" => Atom.to_string(source.domain),
             "transport" => "websocket",
             "credential" => "verified",
             "expires_in_seconds" => token.expire,
             "connected_realm_ref" => source.connected_realm_ref
           }
           |> reject_nil_values()
       }}
    else
      {:error, error} -> {:error, Feishu.Error.map(error)}
    end
  end

  defp credential(credential_id, config) do
    case direct_credential(config) do
      {:ok, credential} ->
        {:ok, credential}

      :error ->
        case Map.fetch(Feishu.Config.credentials!(), credential_id) do
          {:ok, credential} ->
            {:ok, credential}

          :error ->
            {:error,
             Feishu.Error.config("missing Feishu credential profile", %{
               credential_id: credential_id
             })}
        end
    end
  end

  defp direct_credential(%{"app_id" => app_id, "app_secret" => app_secret} = config)
       when is_binary(app_id) and app_id != "" and is_binary(app_secret) and app_secret != "" do
    {:ok,
     %{
       "app_id" => app_id,
       "app_secret" => app_secret,
       "app_type" => Map.get(config, "app_type", "self_built")
     }}
    |> put_optional_credential_secrets(config)
  end

  defp direct_credential(_config), do: :error

  defp put_optional_credential_secrets({:ok, credential}, config) do
    credential =
      credential
      |> maybe_put("verification_token", present_string(Map.get(config, "verification_token")))
      |> maybe_put("encrypt_key", present_string(Map.get(config, "encrypt_key")))

    {:ok, credential}
  end

  defp domain(value) when value in [:feishu, "feishu"], do: {:ok, :feishu}
  defp domain(value) when value in [:lark, "lark"], do: {:ok, :lark}
  defp domain(_value), do: {:error, Feishu.Error.config("Feishu domain must be feishu or lark")}

  defp app_type(value) when value in [:self_built, "self_built"], do: {:ok, :self_built}
  defp app_type(value) when value in [:marketplace, "marketplace"], do: {:ok, :marketplace}

  defp app_type(_value),
    do: {:error, Feishu.Error.config("Feishu app_type must be self_built or marketplace")}

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

  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
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

  defp map_value(map, key), do: Map.get(map, key)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
