defmodule BullXDiscord.Adapter do
  @moduledoc """
  Gateway adapter implementation for Discord.
  """

  @behaviour BullXGateway.Adapter

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXDiscord.{Channel, Config, Delivery, Error, Streamer}

  @impl true
  def adapter_id, do: :discord

  @impl true
  def config_docs do
    %{
      "en-US" => "https://github.com/AgentBull/bullx/blob/main/docs/channels/discord.en-US.md",
      "zh-Hans-CN" =>
        "https://github.com/AgentBull/bullx/blob/main/docs/channels/discord.zh-Hans-CN.md"
    }
  end

  @impl true
  def capabilities, do: [:send, :edit, :stream, :threads]

  @impl true
  def connectivity_check(channel, config) do
    with {:ok, cfg} <- Config.normalize(channel, config),
         {:ok, bot_user} <- verify_bot(cfg),
         :ok <- verify_application(cfg),
         :ok <- validate_command_sync(cfg) do
      {:ok,
       %{
         "adapter" => "discord",
         "channel_id" => cfg.channel_id,
         "application_id" => cfg.application_id,
         "bot_user_id" => id_string(field(bot_user, :id)),
         "capabilities" => Enum.map(capabilities(), &Atom.to_string/1),
         "credential" => %{"status" => "verified"},
         "transport" => %{
           "mode" => "gateway",
           "long_lived_client_started" => false,
           "message_content_intent_required" => true
         },
         "application_commands" => %{"sync_policy" => cfg.application_commands.sync_policy}
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
      Channel.bot_child_spec({channel, cfg})
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

  defp verify_bot(%Config{} = config) do
    Config.with_bot(config, fn -> config.self_api.get() end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp verify_application(%Config{web_login_disabled: true}), do: :ok

  defp verify_application(%Config{client_secret: nil}),
    do: {:error, Error.payload("Discord client_secret is required")}

  defp verify_application(%Config{}), do: :ok

  defp validate_command_sync(%Config{application_commands: %{sync_policy: policy}})
       when policy in ["safe", "off"],
       do: :ok

  defp validate_command_sync(%Config{}) do
    {:error, Error.payload("Discord application command sync policy must be safe or off")}
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
