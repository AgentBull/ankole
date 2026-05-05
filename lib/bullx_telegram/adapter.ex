defmodule BullXTelegram.Adapter do
  @moduledoc """
  Gateway adapter implementation for Telegram.
  """

  @behaviour BullXGateway.Adapter

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXTelegram.{Channel, Config, Delivery, Error, Streamer}

  @impl true
  def adapter_id, do: :telegram

  @impl true
  def config_docs do
    %{
      "en-US" => "https://github.com/AgentBull/bullx/blob/main/docs/channels/telegram.en-US.md",
      "zh-Hans-CN" =>
        "https://github.com/AgentBull/bullx/blob/main/docs/channels/telegram.zh-Hans-CN.md"
    }
  end

  @impl true
  def capabilities, do: [:send, :edit, :stream, :threads]

  @impl true
  def connectivity_check(channel, config) do
    with {:ok, cfg} <- Config.normalize(channel, config),
         :ok <- validate_webhook_connectivity(cfg),
         {:ok, bot} <- verify_bot(cfg),
         :ok <- validate_bot_username(cfg, bot) do
      {:ok,
       %{
         "status" => "ok",
         "adapter" => "telegram",
         "channel_id" => cfg.channel_id,
         "bot_id" => id_string(field(bot, :id)),
         "bot_username" => field(bot, :username),
         "capabilities" => Enum.map(capabilities(), &Atom.to_string/1),
         "credential" => %{"status" => "verified"},
         "transport" => %{
           "mode" => cfg.transport.mode,
           "long_lived_client_started" => false
         }
       }}
    else
      {:error, %{} = error} -> {:error, error}
    end
  end

  @impl true
  def child_specs(channel, config) do
    cfg = Config.normalize!(channel, config)

    [
      {Channel, {channel, cfg}},
      Channel.poller_child_spec({channel, cfg})
    ]
    |> Enum.reject(&is_nil/1)
  end

  @impl true
  def deliver(%GatewayDelivery{} = delivery, %{channel: channel, config: config}) do
    with {:ok, cfg} <- Config.normalize(channel, config) do
      Delivery.deliver(delivery, cfg)
    end
  end

  @impl true
  def stream(%GatewayDelivery{} = delivery, enumerable, %{channel: channel, config: config}) do
    with {:ok, cfg} <- Config.normalize(channel, config) do
      Streamer.stream(delivery, enumerable, cfg)
    end
  end

  defp validate_webhook_connectivity(%Config{transport: %{mode: "webhook"}} = config) do
    Config.validate_webhook_url(config)
  end

  defp validate_webhook_connectivity(%Config{}), do: :ok

  defp verify_bot(%Config{} = config) do
    case Config.request(config, "getMe") do
      {:ok, bot} -> {:ok, bot}
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp validate_bot_username(%Config{bot_username: nil}, _bot), do: :ok

  defp validate_bot_username(%Config{bot_username: expected}, bot) do
    case field(bot, :username) do
      ^expected ->
        :ok

      username when is_binary(username) ->
        compare_bot_username(expected, username)

      _other ->
        {:error,
         Error.config("Telegram bot_username did not match getMe response", %{
           "field" => "bot_username"
         })}
    end
  end

  defp compare_bot_username(expected, username) do
    case String.downcase(expected) == String.downcase(username) do
      true ->
        :ok

      false ->
        {:error,
         Error.config("Telegram bot_username did not match getMe response", %{
           "field" => "bot_username"
         })}
    end
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
