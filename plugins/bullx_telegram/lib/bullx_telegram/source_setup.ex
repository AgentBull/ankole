defmodule BullxTelegram.SourceSetup do
  @moduledoc false

  alias BullX.MailBox.RoutingContext
  alias BullxTelegram.Source

  @sources_key "bullx.plugins.bullx_telegram.im_gateway_sources"

  @spec config_keys() :: %{sources: String.t()}
  def config_keys, do: %{sources: @sources_key}

  @spec form_schema() :: map()
  def form_schema do
    %{
      adapter_id: "telegram",
      label: "Telegram",
      channel_kind: "im",
      help_url: "https://core.telegram.org/bots/api",
      default_source: %{
        "enabled" => true,
        "im_listen_mode" => "all_messages",
        "trusted_realm_by_default" => false
      },
      sections: [
        %{
          key: "source",
          fields: [
            %{path: ["source", "id"], kind: :text, required: true},
            %{
              path: ["source", "bot_token"],
              kind: :secret,
              required: true,
              ui: %{group: "credentials"}
            },
            %{
              path: ["source", "im_listen_mode"],
              kind: :select,
              options: ["addressed_only", "all_messages"]
            }
          ]
        }
      ]
    }
  end

  @spec public_projection() :: map()
  def public_projection do
    configured_sources = BullxTelegram.Config.im_gateway_sources!()
    runtime = runtime_status()

    %{
      adapter_id: "telegram",
      sources: Enum.map(configured_sources, &public_source(&1, runtime))
    }
  end

  @spec cast_source(map(), map()) :: {:ok, map()} | {:error, map()}
  def cast_source(payload, _opts) when is_map(payload) do
    source = payload_map(payload, "source")

    with {:ok, id} <- required_string(source, "id"),
         {:ok, bot_token} <- secret_or_existing(id, source, "bot_token") do
      attrs =
        %{
          "id" => id,
          "enabled" => boolean_field(source, "enabled", true),
          "bot_token" => bot_token,
          "im_listen_mode" => string_field(source, "im_listen_mode", "all_messages"),
          "trusted_realm_by_default" => boolean_field(source, "trusted_realm_by_default", false)
        }
        |> maybe_put("bot_username", string_field(source, "bot_username", nil))

      case BullxTelegram.Config.IMGatewaySources.cast([attrs]) do
        {:ok, [normalized]} -> {:ok, normalized}
        :error -> {:error, %{field: "source", message: "invalid Telegram source"}}
      end
    end
  end

  @spec persist_source(map(), map()) :: :ok | {:error, term()}
  def persist_source(_opts, source) when is_map(source) do
    sources =
      BullxTelegram.Config.im_gateway_sources!()
      |> upsert_source(source)

    BullX.Config.put(@sources_key, Jason.encode!(sources))
  end

  @spec generated_secret_fields() :: [[String.t()]]
  def generated_secret_fields, do: []

  @spec connectivity_check(map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source) when is_map(source), do: Source.connectivity_check(source)

  @spec routing_sample(map()) :: {:ok, map()} | {:error, map()}
  def routing_sample(source) when is_map(source) do
    id = Map.get(source, "id") || Map.get(source, :id)

    %{
      "id" => "setup-routing-sample",
      "source" => "telegram://#{id}",
      "type" => "bullx.message.received",
      "time" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
      "data" => %{
        "channel" => %{"adapter" => "telegram", "id" => id},
        "scope" => %{"id" => "setup-scope", "thread_id" => nil},
        "actor" => %{"external_id" => "telegram:setup-operator"},
        "refs" => %{},
        "reply_address" => %{"adapter" => "telegram", "source_id" => id},
        "routing_facts" => %{"chat_type" => "private"}
      }
    }
    |> RoutingContext.project()
    |> then(&{:ok, &1})
  end

  @spec reconcile_sources() :: {:ok, map()} | {:error, term()}
  def reconcile_sources, do: BullxTelegram.SourceSupervisor.reconcile_sources()

  defp upsert_source(sources, source) when is_list(sources) do
    id = Map.fetch!(source, "id")

    sources
    |> Enum.reject(&((Map.get(&1, "id") || Map.get(&1, :id)) == id))
    |> Kernel.++([source])
  end

  defp public_source(source, runtime) do
    source
    |> Source.public_config()
    |> Map.put("bot_token", secret_status(source["bot_token"]))
    |> Map.put("runtime", runtime_for_source(runtime, source["id"]))
  end

  defp runtime_status do
    case BullxTelegram.SourceSupervisor.runtime_status() do
      {:ok, status} -> status
      {:error, reason} -> %{ready?: false, error: inspect(reason), sources: []}
    end
  end

  defp runtime_for_source(%{sources: sources}, id) do
    Enum.find(sources, %{"ready" => false}, fn source ->
      Map.get(source, :id) == id or Map.get(source, "id") == id
    end)
  end

  defp runtime_for_source(_runtime, _id), do: %{"ready" => false}

  defp payload_map(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      %{} = value -> stringify_keys(value)
      _other -> %{}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp required_string(map, key) do
    case string_field(map, key, nil) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, %{field: key, message: "is required"}}
    end
  end

  defp secret_or_existing(source_id, map, key) do
    case string_field(map, key, nil) do
      value when is_binary(value) ->
        {:ok, value}

      nil ->
        case existing_source_secret(source_id, key) do
          value when is_binary(value) -> {:ok, value}
          _value -> {:error, %{field: key, message: "is required"}}
        end
    end
  end

  defp existing_source_secret(source_id, key) do
    BullxTelegram.Config.im_gateway_sources!()
    |> Enum.find(fn source ->
      (Map.get(source, "id") || Map.get(source, :id)) == source_id
    end)
    |> case do
      %{} = source -> Map.get(source, key) || Map.get(source, String.to_atom(key))
      _source -> nil
    end
  end

  defp string_field(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp boolean_field(map, key, default) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      nil -> default
      _value -> default
    end
  end

  defp secret_status(value) when is_binary(value) and value != "",
    do: %{"present" => true, "masked" => "******"}

  defp secret_status(_value), do: %{"present" => false, "masked" => ""}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
