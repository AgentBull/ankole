defmodule Feishu.ChannelAdapter do
  @moduledoc """
  Channel adapter for Feishu/Lark sources.

  The adapter normalizes provider input into decoded CloudEvents. It does not
  route mail, persist IM facts, or decide Principal verification.
  """

  @behaviour BullX.IMGateway.ChannelAdapter

  alias BullX.IMGateway.ChannelAdapter, as: IMGatewayAdapter
  alias Feishu.{DirectCommand, EventMapper, Source}

  @impl BullX.IMGateway.ChannelAdapter
  def normalize_inbound(source_config, provider_input) when is_map(source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      provider_input
      |> EventMapper.map(source)
      |> handle_mapped(source)
    else
      {:error, error} -> {:error, Feishu.Error.map(error)}
    end
  end

  @impl BullX.IMGateway.ChannelAdapter
  def deliver(source_config, reply_address, outbound, opts) do
    Feishu.Outbound.deliver(source_config, reply_address, outbound, opts)
  end

  @impl BullX.IMGateway.ChannelAdapter
  def consume_stream(source_config, reply_address, stream_id, opts) do
    Feishu.StreamingCard.consume(source_config, reply_address, stream_id, opts)
  end

  @impl BullX.IMGateway.ChannelAdapter
  def fetch_source(source_id), do: Source.fetch_enabled_source(source_id)

  @impl BullX.IMGateway.ChannelAdapter
  def capabilities do
    %{
      inbound_modes: [:websocket],
      outbound_ops: [:send, :edit, :recall, :stream],
      stream_strategy: :native_cardkit,
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
      identity_evidence: [:channel_actor, :oidc_login_subject],
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

  defp handle_mapped({:ok, %{attrs: attrs}}, %Source{}),
    do: IMGatewayAdapter.build_message_event(attrs)

  defp handle_mapped({:error, error}, _source), do: {:error, Feishu.Error.map(error)}
end
