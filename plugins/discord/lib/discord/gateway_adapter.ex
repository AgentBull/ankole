defmodule Discord.GatewayAdapter do
  @moduledoc """
  Gateway adapter implementation for Discord sources.
  """

  @behaviour BullX.Gateway.Adapter

  alias BullX.Gateway.Delivery, as: GatewayDelivery
  alias BullX.Gateway.SourceConfig
  alias Discord.{Delivery, Error, EventMapper, Source, Streamer}

  @impl BullX.Gateway.Adapter
  def config_schema do
    %{
      "credential_id" => %{type: "string", default: "default", secret: false},
      "bot_user_id" => %{type: "string", required: false},
      "oauth2" => %{type: "object", required: false},
      "auto_thread" => %{type: "object", required: false},
      "attention" => %{type: "object", required: false},
      "application_commands" => %{type: "object", required: false},
      "direct_command_dedupe_ttl_seconds" => %{type: "integer", default: 300},
      "message_context_ttl_seconds" => %{type: "integer", default: 2_592_000},
      "thread_ownership_cache_ttl_seconds" => %{type: "integer", default: 86_400},
      "stream_update_interval_ms" => %{type: "integer", default: 1_000},
      "stream_chunk_soft_limit" => %{type: "integer", default: 1_850}
    }
  end

  @impl BullX.Gateway.Adapter
  def normalize_config(config) when is_map(config) do
    source_config = %SourceConfig{
      adapter: "discord",
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
      inbound_modes: [:gateway_ws, :interaction],
      outbound_ops: [:send, :edit, :stream],
      content_kinds: [:text, :image, :audio, :video, :file, :card],
      stream_strategy: :edit_accumulate,
      features: [:threads, :application_commands, :ephemeral_replies]
    }
  end

  @impl BullX.Gateway.Adapter
  def connectivity_check(%SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config),
         {:ok, bot_user} <- fetch_bot_user(source),
         :ok <- validate_bot_user(source, bot_user) do
      {:ok,
       %{
         status: :ok,
         adapter: "discord",
         channel_id: source.channel_id,
         capabilities: [:inbound, :send, :edit, :stream, :threads, :application_commands],
         details:
           %{
             "transport" => "gateway",
             "application_id" => source.application_id,
             "bot_user_id" => bot_user_id(bot_user),
             "credential" => "verified",
             "message_content_intent_required" => true,
             "application_commands_sync_policy" => source.application_commands["sync_policy"]
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
    Discord.Supervisor.child_spec(source_config)
  end

  @impl BullX.Gateway.Adapter
  def normalize_inbound(payload, %SourceConfig{} = source_config, _metadata)
      when is_map(payload) do
    with {:ok, source} <- Source.normalize(source_config) do
      case EventMapper.map_event(payload, source) do
        {:ok, %{input: input}} -> {:ok, input}
        {:direct_command, _command} -> {:error, Error.ignored(:direct_command)}
        {:ignore, reason} -> {:error, Error.ignored(reason)}
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl BullX.Gateway.Adapter
  def deliver(%GatewayDelivery{} = delivery, %SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      Delivery.deliver(delivery, source)
    end
  end

  @impl BullX.Gateway.Adapter
  def stream(%GatewayDelivery{} = delivery, enumerable, %SourceConfig{} = source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      Streamer.stream(delivery, enumerable, source)
    end
  end

  defp fetch_bot_user(%Source{} = source) do
    Source.with_bot(source, fn -> source.self_api.get() end)
    |> case do
      {:ok, %{} = user} -> {:ok, user}
      {:error, error} -> {:error, Error.map(error)}
      other -> {:error, Error.map(other)}
    end
  end

  defp validate_bot_user(%Source{bot_user_id: nil}, _user), do: :ok

  defp validate_bot_user(%Source{bot_user_id: expected}, user) do
    actual = bot_user_id(user)

    case is_binary(actual) and String.downcase(actual) == String.downcase(expected) do
      true ->
        :ok

      false ->
        {:error,
         Error.config("Discord bot_user_id did not match the resolved bot user", %{
           "field" => "bot_user_id",
           "expected" => expected,
           "actual" => actual
         })}
    end
  end

  defp bot_user_id(%{} = user) do
    case Map.get(user, :id) || Map.get(user, "id") do
      nil -> nil
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value -> to_string(value)
    end
  end

  defp bot_user_id(_user), do: nil

  defp connectivity_error(%{"kind" => kind} = error)
       when kind in [
              "auth",
              "config",
              "network",
              "permission",
              "rate_limit",
              "provider_unavailable",
              "unknown"
            ] do
    error
  end

  defp connectivity_error(error), do: Error.map(error)
end
