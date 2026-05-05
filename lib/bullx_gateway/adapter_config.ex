defmodule BullXGateway.AdapterConfig do
  @moduledoc """
  JSON-safe setup/configuration boundary for Gateway adapter lists.

  The runtime Gateway still consumes adapter specs in the existing
  `{{adapter, channel_id}, Module, config}` shape. Setup stores a richer
  JSON-compatible list in `app_configs` so disabled drafts, nested adapter
  objects, and write-only credentials can survive browser edits without
  becoming runtime children.
  """

  @config_key "bullx.gateway.adapters"
  @secret_fields ~w(app_secret)

  @feishu_defaults %{
    "id" => "feishu:",
    "adapter" => "feishu",
    "channel_id" => "",
    "enabled" => true,
    "web_login_disabled" => false,
    "domain" => "feishu",
    "authn" => %{
      "external_org_members" => %{
        "enabled" => false,
        "tenant_key" => ""
      }
    },
    "credentials" => %{
      "app_id" => "",
      "app_secret" => ""
    },
    "advanced" => %{
      "dedupe_ttl_ms" => :timer.minutes(5),
      "message_context_ttl_ms" => :timer.hours(24) * 30,
      "card_action_dedupe_ttl_ms" => :timer.minutes(15),
      "inline_media_max_bytes" => 524_288,
      "stream_update_interval_ms" => 100
    }
  }

  @type entry :: map()
  @type runtime_spec :: {BullXGateway.Delivery.channel(), module(), map()}

  @spec config_key() :: String.t()
  def config_key, do: @config_key

  @spec default_entry(String.t()) :: entry()
  def default_entry("feishu"), do: Map.put(@feishu_defaults, "id", unique_entry_id("feishu"))
  def default_entry(_adapter), do: default_entry("feishu")

  @spec catalog(String.t() | atom()) :: [map()]
  def catalog(locale \\ "en-US") do
    [
      %{
        "adapter" => "feishu",
        "label" => "Feishu / Lark",
        "module" => inspect(BullXFeishu.Adapter),
        "transport" => "websocket",
        "config_doc_url" => BullXGateway.Adapter.config_doc_url(BullXFeishu.Adapter, locale),
        "authn_policies" => [
          %{
            "type" => "external_org_members",
            "source_path" => "metadata.tenant_key",
            "field" => "tenant_key"
          }
        ],
        "default_entry" => default_entry("feishu")
      }
    ]
  end

  @spec load_public_entries() :: [entry()]
  def load_public_entries do
    Enum.map(existing_entries(), &public_entry/1)
  end

  @spec persisted_entries() :: [entry()]
  def persisted_entries do
    case BullX.Config.Cache.get_raw(@config_key) do
      {:ok, raw} -> decode_entries(raw)
      :error -> []
    end
  end

  @spec existing_entries() :: [entry()]
  def existing_entries do
    case persisted_entries() do
      [_ | _] = entries ->
        entries

      [] ->
        BullX.Config.Gateway.adapters()
        |> entries_from_runtime_specs()
    end
  end

  @spec normalize_entry(term(), keyword()) :: {:ok, entry()} | {:error, map()}
  def normalize_entry(entry, opts \\ []) do
    existing_entries = Keyword.get(opts, :existing_entries, [])

    with {:ok, raw} <- normalize_map(entry),
         {:ok, adapter} <- normalize_adapter(raw),
         {:ok, channel_id} <- present_string(raw, "channel_id"),
         existing <- find_existing_entry(raw, adapter, channel_id, existing_entries) do
      defaults = defaults_for(adapter, channel_id)

      raw
      |> merge_default_entry(defaults)
      |> merge_existing_secrets(existing)
      |> normalize_known_entry(adapter, channel_id)
    end
  end

  @spec normalize_entries(term(), keyword()) :: {:ok, [entry()]} | {:error, [map()]}
  def normalize_entries(entries, opts \\ [])

  def normalize_entries(entries, opts) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      case normalize_entry(entry, opts) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, error} -> {:error, put_error_path(error, "adapters[#{index}]")}
      end
    end)
    |> collect_normalized_entries()
    |> validate_enabled_duplicates()
  end

  def normalize_entries(_entries, _opts) do
    {:error, [validation_error("payload", "adapters must be a list", "adapters")]}
  end

  @spec encode_for_storage(term(), keyword()) :: {:ok, String.t(), [entry()]} | {:error, [map()]}
  def encode_for_storage(entries, opts \\ []) do
    with {:ok, normalized} <- normalize_entries(entries, opts),
         {:ok, _runtime_specs} <- runtime_specs(normalized),
         {:ok, encoded} <- Jason.encode(normalized) do
      {:ok, encoded, normalized}
    else
      {:error, [%{} | _] = errors} ->
        {:error, errors}

      {:error, %Jason.EncodeError{} = error} ->
        {:error, [validation_error("payload", Exception.message(error), "adapters")]}

      {:error, error} ->
        {:error, [validation_error("payload", inspect(error), "adapters")]}
    end
  end

  @spec runtime_specs([entry()]) :: {:ok, [runtime_spec()]} | {:error, [map()]}
  def runtime_specs(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case runtime_spec(entry) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, spec} ->
          {:cont, {:ok, [spec | acc]}}

        {:error, error} ->
          {:halt, {:error, [put_error_path(error, "adapters[#{index}]")]}}
      end
    end)
    |> reverse_runtime_specs()
  end

  @spec runtime_spec(entry()) :: {:ok, runtime_spec() | nil} | {:error, map()}
  def runtime_spec(%{"enabled" => false}), do: {:ok, nil}

  def runtime_spec(%{"adapter" => "feishu", "channel_id" => channel_id} = entry) do
    channel = {:feishu, channel_id}
    config = feishu_runtime_config(entry)

    with {:ok, _cfg} <- BullXFeishu.Config.normalize(channel, config) do
      {:ok, {channel, BullXFeishu.Adapter, config}}
    else
      {:error, error} -> {:error, adapter_error(error)}
    end
  end

  def runtime_spec(%{"adapter" => adapter}) do
    {:error, validation_error("config", "unsupported adapter #{inspect(adapter)}", "adapter")}
  end

  @spec connectivity_check(entry()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(%{"enabled" => false}) do
    {:ok, %{"status" => "skipped", "message" => "disabled adapter draft"}}
  end

  def connectivity_check(entry) do
    with {:ok, {channel, module, config}} <- runtime_spec(entry) do
      module.connectivity_check(channel, config)
    end
  end

  @spec fingerprint(entry()) :: String.t()
  def fingerprint(entry) when is_map(entry) do
    entry
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec cast(term()) :: {:ok, [runtime_spec()]} | :error
  def cast(value) when is_list(value) do
    cond do
      runtime_specs_shape?(value) ->
        {:ok, value}

      true ->
        with {:ok, entries} <- normalize_entries(value),
             {:ok, specs} <- runtime_specs(entries) do
          {:ok, specs}
        else
          _ -> :error
        end
    end
  end

  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value) do
      cast(decoded)
    else
      _ -> :error
    end
  end

  def cast(_value), do: :error

  @spec public_entry(entry()) :: entry()
  def public_entry(entry) when is_map(entry) do
    entry =
      merge_default_entry(
        entry,
        defaults_for(Map.get(entry, "adapter"), Map.get(entry, "channel_id"))
      )

    credentials = Map.get(entry, "credentials", %{})

    secret_status =
      Map.new(@secret_fields, fn field ->
        status =
          case present_binary?(Map.get(credentials, field)) do
            true -> "stored"
            false -> "missing"
          end

        {field, status}
      end)

    redacted_credentials =
      Enum.reduce(@secret_fields, credentials, fn field, acc ->
        Map.put(acc, field, "")
      end)

    entry
    |> Map.put("credentials", redacted_credentials)
    |> Map.put("secret_status", secret_status)
  end

  defp decode_entries(raw) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(raw),
         {:ok, entries} <- normalize_entries(decoded) do
      entries
    else
      _ -> []
    end
  end

  defp entries_from_runtime_specs(specs) when is_list(specs) do
    Enum.flat_map(specs, fn
      {{adapter, channel_id}, BullXFeishu.Adapter, config}
      when adapter in [:feishu, "feishu"] and is_binary(channel_id) and is_map(config) ->
        [entry_from_feishu_runtime_config(channel_id, config)]

      _other ->
        []
    end)
  end

  defp entry_from_feishu_runtime_config(channel_id, config) do
    domain = get_value(config, :domain, "feishu")

    @feishu_defaults
    |> Map.put("id", "feishu:#{channel_id}")
    |> Map.put("channel_id", channel_id)
    |> Map.put("enabled", true)
    |> Map.put("web_login_disabled", get_value(config, :web_login_disabled, false) == true)
    |> Map.put("domain", atom_to_string(domain))
    |> Map.put("credentials", %{
      "app_id" => get_value(config, :app_id, ""),
      "app_secret" => get_value(config, :app_secret, "")
    })
    |> Map.put("advanced", normalize_runtime_advanced_map(config))
  end

  defp normalize_known_entry(entry, "feishu", channel_id) do
    credentials = normalize_credentials(Map.get(entry, "credentials", %{}))
    defaults = @feishu_defaults

    normalized =
      %{
        "id" => present_or_default(Map.get(entry, "id"), "feishu:#{channel_id}"),
        "adapter" => "feishu",
        "channel_id" => channel_id,
        "enabled" => normalize_boolean(Map.get(entry, "enabled"), defaults["enabled"]),
        "web_login_disabled" =>
          normalize_boolean(Map.get(entry, "web_login_disabled"), defaults["web_login_disabled"]),
        "domain" => normalize_domain(Map.get(entry, "domain")),
        "authn" => normalize_authn_map(Map.get(entry, "authn", %{})),
        "credentials" => credentials,
        "advanced" => normalize_advanced_map(Map.get(entry, "advanced", %{}))
      }

    validate_required_for_enabled(normalized)
  end

  defp normalize_adapter(%{"adapter" => adapter}) when adapter in ["feishu", :feishu],
    do: {:ok, "feishu"}

  defp normalize_adapter(%{"adapter" => adapter}) do
    {:error, validation_error("config", "unsupported adapter #{inspect(adapter)}", "adapter")}
  end

  defp normalize_adapter(_entry), do: {:ok, "feishu"}

  defp validate_required_for_enabled(%{"enabled" => false} = entry), do: {:ok, entry}

  defp validate_required_for_enabled(%{"credentials" => credentials} = entry) do
    cond do
      not present_binary?(credentials["app_id"]) ->
        {:error, validation_error("config", "Feishu app_id is required", "credentials.app_id")}

      not present_binary?(credentials["app_secret"]) ->
        {:error,
         validation_error("config", "Feishu app_secret is required", "credentials.app_secret")}

      external_org_members_enabled?(entry) and not present_binary?(external_tenant_key(entry)) ->
        {:error,
         validation_error(
           "config",
           "Feishu tenant_key is required",
           "authn.external_org_members.tenant_key"
         )}

      entry["domain"] not in ["feishu", "lark"] ->
        {:error, validation_error("config", "Feishu domain must be feishu or lark", "domain")}

      true ->
        {:ok, entry}
    end
  end

  defp validate_enabled_duplicates({:error, _errors} = error), do: error

  defp validate_enabled_duplicates({:ok, entries}) do
    entries
    |> Enum.filter(&Map.get(&1, "enabled", true))
    |> Enum.map(&{Map.get(&1, "adapter"), Map.get(&1, "channel_id")})
    |> duplicate_key()
    |> case do
      nil ->
        {:ok, entries}

      {adapter, channel_id} ->
        {:error,
         [
           validation_error(
             "config",
             "enabled adapter channel #{adapter}:#{channel_id} is duplicated",
             "adapters"
           )
         ]}
    end
  end

  defp duplicate_key(keys) do
    Enum.reduce_while(keys, MapSet.new(), fn key, seen ->
      case MapSet.member?(seen, key) do
        true -> {:halt, key}
        false -> {:cont, MapSet.put(seen, key)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  defp collect_normalized_entries(results) do
    errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, error} -> error end)

    case errors do
      [] ->
        {:ok, Enum.map(results, fn {:ok, entry} -> entry end)}

      [_ | _] ->
        {:error, errors}
    end
  end

  defp reverse_runtime_specs({:ok, specs}), do: {:ok, Enum.reverse(specs)}
  defp reverse_runtime_specs({:error, _} = error), do: error

  defp normalize_map(map) when is_map(map) do
    map
    |> stringify_keys()
    |> case do
      %{} = normalized -> {:ok, normalized}
      :error -> {:error, validation_error("payload", "entry must have string or atom keys", "")}
    end
  end

  defp normalize_map(_value),
    do: {:error, validation_error("payload", "entry must be an object", "")}

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce_while(map, %{}, fn
      {key, value}, acc when is_binary(key) ->
        {:cont, Map.put(acc, key, stringify_nested(value))}

      {key, value}, acc when is_atom(key) ->
        {:cont, Map.put(acc, Atom.to_string(key), stringify_nested(value))}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp stringify_nested(%_{} = struct), do: struct

  defp stringify_nested(map) when is_map(map), do: stringify_keys(map)
  defp stringify_nested(list) when is_list(list), do: Enum.map(list, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp defaults_for("feishu", channel_id) when is_binary(channel_id) do
    @feishu_defaults
    |> Map.put("id", "feishu:#{channel_id}")
    |> Map.put("channel_id", channel_id)
  end

  defp defaults_for("feishu", _channel_id), do: @feishu_defaults
  defp defaults_for(_adapter, _channel_id), do: @feishu_defaults

  defp merge_default_entry(entry, defaults) when is_map(defaults) do
    Map.merge(defaults, entry, fn
      _key, default, value when is_map(default) and is_map(value) ->
        Map.merge(default, value)

      _key, _default, value ->
        value
    end)
  end

  defp find_existing_entry(_raw, _adapter, _channel_id, []), do: nil

  defp find_existing_entry(raw, adapter, channel_id, existing_entries) do
    id = Map.get(raw, "id")

    Enum.find(existing_entries, fn existing ->
      same_id?(existing, id) or
        (Map.get(existing, "adapter") == adapter and Map.get(existing, "channel_id") == channel_id)
    end)
  end

  defp same_id?(_existing, id) when not is_binary(id), do: false
  defp same_id?(existing, id), do: Map.get(existing, "id") == id

  defp merge_existing_secrets(entry, nil), do: entry

  defp merge_existing_secrets(entry, existing) do
    submitted_credentials = Map.get(entry, "credentials", %{})
    existing_credentials = Map.get(existing, "credentials", %{})

    credentials =
      Enum.reduce(@secret_fields, submitted_credentials, fn field, acc ->
        case present_binary?(Map.get(acc, field)) do
          true -> acc
          false -> maybe_put_existing_secret(acc, field, Map.get(existing_credentials, field))
        end
      end)

    Map.put(entry, "credentials", credentials)
  end

  defp maybe_put_existing_secret(credentials, _field, value) when not is_binary(value),
    do: credentials

  defp maybe_put_existing_secret(credentials, field, value) do
    case String.trim(value) do
      "" -> credentials
      trimmed -> Map.put(credentials, field, trimmed)
    end
  end

  defp normalize_credentials(value) do
    value = normalize_nested_map(value)

    Map.merge(@feishu_defaults["credentials"], %{
      "app_id" => normalized_string(value["app_id"]),
      "app_secret" => normalized_string(value["app_secret"])
    })
  end

  defp normalize_advanced_map(value) when is_map(value) do
    value = normalize_nested_map(value)
    defaults = @feishu_defaults["advanced"]

    Map.new(defaults, fn {key, default} ->
      {key, non_negative_integer(value[key], default)}
    end)
  end

  defp normalize_advanced_map(_value), do: @feishu_defaults["advanced"]

  defp normalize_authn_map(value) when is_map(value) do
    value = normalize_nested_map(value)
    external_org_members = normalize_nested_map(value["external_org_members"])

    %{
      "external_org_members" => %{
        "enabled" => normalize_boolean(external_org_members["enabled"], false),
        "tenant_key" => normalized_string(external_org_members["tenant_key"])
      }
    }
  end

  defp normalize_authn_map(_value), do: @feishu_defaults["authn"]

  defp normalize_runtime_advanced_map(config) when is_map(config) do
    defaults = @feishu_defaults["advanced"]

    Map.new(defaults, fn {key, default} ->
      {key, non_negative_integer(get_runtime_advanced_value(config, key, default), default)}
    end)
  end

  defp normalize_runtime_advanced_map(_config), do: @feishu_defaults["advanced"]

  defp get_runtime_advanced_value(config, "dedupe_ttl_ms", default),
    do: get_value(config, :dedupe_ttl_ms, default)

  defp get_runtime_advanced_value(config, "message_context_ttl_ms", default),
    do: get_value(config, :message_context_ttl_ms, default)

  defp get_runtime_advanced_value(config, "card_action_dedupe_ttl_ms", default),
    do: get_value(config, :card_action_dedupe_ttl_ms, default)

  defp get_runtime_advanced_value(config, "inline_media_max_bytes", default),
    do: get_value(config, :inline_media_max_bytes, default)

  defp get_runtime_advanced_value(config, "stream_update_interval_ms", default),
    do: get_value(config, :stream_update_interval_ms, default)

  defp normalize_nested_map(value) do
    case stringify_nested(value) do
      %{} = map -> map
      _other -> %{}
    end
  end

  defp present_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, validation_error("config", "#{key} is required", key)}
          trimmed -> {:ok, trimmed}
        end

      value when is_atom(value) ->
        {:ok, Atom.to_string(value)}

      _other ->
        {:error, validation_error("config", "#{key} is required", key)}
    end
  end

  defp normalized_string(value) when is_binary(value), do: String.trim(value)
  defp normalized_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalized_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalized_string(_value), do: ""

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false

  defp normalize_boolean(value, _default) when value in [true, false], do: value
  defp normalize_boolean("true", _default), do: true
  defp normalize_boolean("false", _default), do: false
  defp normalize_boolean("1", _default), do: true
  defp normalize_boolean("0", _default), do: false
  defp normalize_boolean(_value, default), do: default

  defp normalize_domain(value) when value in [:feishu, :lark], do: Atom.to_string(value)
  defp normalize_domain(value) when value in ["feishu", "lark"], do: value

  defp normalize_domain(value) when is_binary(value) do
    value = String.trim(value)

    case value do
      "" -> "feishu"
      value -> value
    end
  end

  defp normalize_domain(_value), do: "feishu"

  defp non_negative_integer(value, default), do: bounded_integer(value, default, 0, :infinity)

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

  defp feishu_runtime_config(entry) do
    credentials = entry["credentials"]
    advanced = entry["advanced"]

    %{
      app_id: credentials["app_id"],
      app_secret: credentials["app_secret"],
      web_login_disabled: entry["web_login_disabled"],
      domain: runtime_domain(entry["domain"]),
      dedupe_ttl_ms: advanced["dedupe_ttl_ms"],
      message_context_ttl_ms: advanced["message_context_ttl_ms"],
      card_action_dedupe_ttl_ms: advanced["card_action_dedupe_ttl_ms"],
      inline_media_max_bytes: advanced["inline_media_max_bytes"],
      stream_update_interval_ms: advanced["stream_update_interval_ms"]
    }
  end

  defp runtime_domain("feishu"), do: :feishu
  defp runtime_domain("lark"), do: :lark
  defp runtime_domain(value), do: value

  defp adapter_error(%{"kind" => _} = error), do: error
  defp adapter_error(error), do: validation_error("config", inspect(error), "adapter")

  defp validation_error(kind, message, field) do
    %{
      "kind" => kind,
      "message" => message,
      "details" => %{"field" => field}
    }
  end

  defp put_error_path(%{"details" => details} = error, prefix) do
    field = Map.get(details, "field", "")
    path = [prefix, field] |> Enum.reject(&(&1 == "")) |> Enum.join(".")
    put_in(error, ["details", "field"], path)
  end

  defp runtime_specs_shape?(specs) do
    Enum.all?(specs, fn
      {{adapter, channel_id}, module, config}
      when (is_atom(adapter) or is_binary(adapter)) and is_binary(channel_id) and is_atom(module) and
             is_map(config) ->
        true

      _other ->
        false
    end)
  end

  defp get_value(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp get_value(_map, _key, default), do: default

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value) when is_binary(value), do: value
  defp atom_to_string(value), do: to_string(value)

  defp external_org_members_enabled?(%{
         "authn" => %{"external_org_members" => %{"enabled" => true}}
       }),
       do: true

  defp external_org_members_enabled?(_entry), do: false

  defp external_tenant_key(%{"authn" => %{"external_org_members" => policy}}),
    do: Map.get(policy, "tenant_key")

  defp external_tenant_key(_entry), do: nil

  defp present_or_default(value, default) do
    case normalized_string(value) do
      "" -> default
      normalized -> normalized
    end
  end

  defp unique_entry_id(adapter) do
    "#{adapter}:#{System.unique_integer([:positive])}"
  end
end
