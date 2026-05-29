defmodule Discord.ChannelAdapter do
  @moduledoc """
  Channel adapter for Discord sources.

  The adapter normalizes Discord gateway and interaction occurrences into
  decoded CloudEvents. It does not route mail, persist IM facts, or decide
  Principal verification.
  """

  @behaviour BullX.IMGateway.ChannelAdapter

  alias BullX.IMGateway.ChannelAdapter, as: IMGatewayAdapter
  alias Discord.{DirectCommand, EventMapper, Source}

  @impl BullX.IMGateway.ChannelAdapter
  def normalize_inbound(source_config, provider_input) when is_map(source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      provider_input
      |> EventMapper.map(source)
      |> handle_mapped(source)
    else
      {:error, error} -> {:error, Discord.Error.map(error)}
    end
  end

  @impl BullX.IMGateway.ChannelAdapter
  def deliver(source_config, reply_address, outbound, opts) do
    Discord.Outbound.deliver(source_config, reply_address, outbound, opts)
  end

  @impl BullX.IMGateway.ChannelAdapter
  def consume_stream(source_config, reply_address, stream_id, opts) do
    Discord.Streamer.consume(source_config, reply_address, stream_id, opts)
  end

  @impl BullX.IMGateway.ChannelAdapter
  def fetch_source(source_id), do: Source.fetch_enabled_source(source_id)

  @impl BullX.IMGateway.ChannelAdapter
  def capabilities do
    %{
      inbound_modes: [:discord_gateway_ws, :interaction],
      outbound_ops: [:send, :edit, :stream],
      content_kinds: [
        :text,
        :image,
        :audio,
        :video,
        :file,
        :card,
        :control_notice,
        :progress_notice
      ],
      features: [:threads, :application_commands, :ephemeral_provider_responses, :oauth2_login],
      stream_strategy: :edit_accumulate,
      im_listen_modes: Source.im_listen_modes()
    }
  end

  @spec connectivity_check(map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source_config), do: Source.connectivity_check(source_config)

  defp handle_mapped({:ignore, _reason}, _source), do: :ignore

  defp handle_mapped({:direct_command, command}, %Source{} = source) do
    case DirectCommand.handle(source, command) do
      {:ok, _result} -> :ignore
      {:error, error} -> {:error, error}
    end
  end

  defp handle_mapped({:ok, mapped}, %Source{}),
    do: IMGatewayAdapter.build_message_event(mapped.attrs)

  defp handle_mapped({:error, error}, _source), do: {:error, Discord.Error.map(error)}
end
