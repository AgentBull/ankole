defmodule BullxTelegram.GatewayAdapter do
  @moduledoc """
  Gateway adapter implementation for Telegram sources.
  """

  @behaviour BullX.Gateway.Adapter

  alias BullX.Gateway.{Delivery, SourceConfig}
  alias BullxTelegram.Delivery, as: TelegramDelivery
  alias BullxTelegram.{Error, Source, Streamer, UpdateMapper}

  @impl BullX.Gateway.Adapter
  def config_schema do
    %{
      "credential_id" => %{type: "string", default: "default", secret: false},
      "bot_username" => %{type: "string", required: false},
      "web_login_disabled" => %{type: "boolean", default: false},
      "poll_timeout_s" => %{type: "integer", default: 30},
      "poll_limit" => %{type: "integer", default: 100, min: 1, max: 100},
      "poll_retry_max" => %{type: "integer", default: 10},
      "flood_wait_max_ms" => %{type: "integer", default: 5_000},
      "stream_update_interval_ms" => %{type: "integer", default: 1_000},
      "stream_chunk_soft_limit" => %{type: "integer", default: 3_900},
      "direct_command_dedupe_ttl_seconds" => %{type: "integer", default: 300},
      "message_context_ttl_seconds" => %{type: "integer", default: 2_592_000},
      "attention" => %{type: "object", required: false},
      "commands" => %{type: "object", required: false}
    }
  end

  @impl BullX.Gateway.Adapter
  def normalize_config(config) when is_map(config) do
    source_config = %SourceConfig{
      adapter: "telegram",
      channel_id: "_validation",
      config: config
    }

    case Source.normalize(source_config) do
      {:ok, source} -> {:ok, Source.public_config(source.source_config)}
      {:error, error} -> {:error, error}
    end
  end

  @impl BullX.Gateway.Adapter
  def public_config(config) when is_map(config), do: Source.public_config(config)

  @impl BullX.Gateway.Adapter
  def capabilities do
    %{
      inbound_modes: [:polling],
      outbound_ops: [:send, :edit, :stream],
      content_kinds: [:text, :image, :audio, :video, :file, :card],
      stream_strategy: :edit_accumulate,
      features: [:threads]
    }
  end

  @impl BullX.Gateway.Adapter
  def connectivity_check(%SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config),
         {:ok, bot} <- fetch_bot(source),
         :ok <- validate_bot_username(source, bot) do
      {:ok,
       %{
         status: :ok,
         adapter: "telegram",
         channel_id: source.channel_id,
         capabilities: [:inbound, :send, :edit, :stream, :threads],
         details: %{
           "transport" => "polling",
           "bot_id" => to_string(Map.get(bot, "id") || ""),
           "bot_username" => Map.get(bot, "username"),
           "credential" => "verified"
         }
         |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
         |> Map.new()
       }}
    else
      {:error, error} -> {:error, connectivity_error(error)}
    end
  end

  def connectivity_check(%{} = source) do
    with {:ok, source} <- SourceConfig.normalize(source) do
      connectivity_check(source)
    end
  end

  @impl BullX.Gateway.Adapter
  def source_child_spec(%SourceConfig{enabled?: false}), do: :ignore
  def source_child_spec(%SourceConfig{} = source_config) do
    BullxTelegram.Supervisor.child_spec(source_config)
  end

  @impl BullX.Gateway.Adapter
  def normalize_inbound(payload, %SourceConfig{} = source_config, _metadata)
      when is_map(payload) do
    with {:ok, source} <- Source.normalize(source_config) do
      case UpdateMapper.map_update(payload, source) do
        {:ok, %{input: input}} -> {:ok, input}
        {:direct_command, _command} -> {:error, Error.ignored(:direct_command)}
        {:ignore, reason} -> {:error, Error.ignored(reason)}
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl BullX.Gateway.Adapter
  def deliver(%Delivery{} = delivery, %SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      TelegramDelivery.deliver(delivery, source)
    end
  end

  @impl BullX.Gateway.Adapter
  def stream(%Delivery{} = delivery, enumerable, %SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      Streamer.stream(delivery, enumerable, source)
    end
  end

  defp fetch_bot(%Source{} = source) do
    case Source.request(source, "getMe") do
      {:ok, %{} = bot} -> {:ok, bot}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_bot_username(%Source{bot_username: nil}, _bot), do: :ok

  defp validate_bot_username(%Source{bot_username: expected}, bot) do
    case Map.get(bot, "username") do
      ^expected ->
        :ok

      username when is_binary(username) ->
        case String.downcase(expected) == String.downcase(username) do
          true ->
            :ok

          false ->
            {:error,
             Error.config("Telegram bot_username did not match getMe response", %{
               "field" => "bot_username",
               "expected" => expected,
               "actual" => username
             })}
        end

      _other ->
        {:error,
         Error.config("Telegram bot_username did not match getMe response", %{
           "field" => "bot_username",
           "expected" => expected
         })}
    end
  end

  defp connectivity_error(%{"kind" => kind} = error)
       when kind in [
              "auth",
              "config",
              "network",
              "permission",
              "rate_limit",
              "polling_conflict",
              "provider_unavailable",
              "unknown"
            ] do
    error
  end

  defp connectivity_error(error), do: Error.map(error)
end
