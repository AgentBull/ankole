defmodule BullX.Integration.IMGateway.MockIM.ChannelAdapter do
  @moduledoc """
  Mock `BullX.IMGateway.ChannelAdapter`. Inbound is mapped by
  `BullX.Integration.IMGateway.MockIM.EventMapper`; outbound (`deliver/4`) and streaming
  (`consume_stream/4`) are captured into `BullX.Integration.IMGateway.MockIM.Server` so tests can
  assert the exact send / edit / recall / stream transcript the agent produced.
  """

  @behaviour BullX.IMGateway.ChannelAdapter

  alias BullX.Integration.IMGateway.MockIM.{EventMapper, Server}

  @impl BullX.IMGateway.ChannelAdapter
  def normalize_inbound(source, %{kind: _kind} = provider_input) when is_map(source),
    do: EventMapper.build(source, provider_input)

  def normalize_inbound(_source, :ignore), do: :ignore
  def normalize_inbound(_source, _other), do: {:error, %{"kind" => "invalid_input"}}

  @impl BullX.IMGateway.ChannelAdapter
  def fetch_source(source_id) when is_binary(source_id),
    do: {:ok, %{"id" => source_id, "adapter" => "mock", "trusted_realm_by_default" => true}}

  @impl BullX.IMGateway.ChannelAdapter
  def deliver(source, reply_address, outbound, opts) do
    case Server.fail_delivery?() do
      true ->
        reason = %{"kind" => "network", "message" => "mock delivery failure", "details" => %{}}
        record_failed_delivery(reply_address, outbound, reason)
        {:error, reason}

      false ->
        do_deliver(source, reply_address, outbound, opts)
    end
  end

  defp record_failed_delivery(reply_address, outbound, reason) do
    Server.record_delivery_failure(%{
      op: outbound["op"] || "send",
      content: outbound["content"],
      text: outbound_text(outbound["content"]),
      target_external_id: outbound["target_external_id"],
      scope_id: reply_address["scope_id"],
      reply_address: reply_address,
      safe_error: reason
    })
  end

  defp do_deliver(_source, reply_address, outbound, _opts) do
    op = outbound["op"] || "send"
    external_id = "mock-ext-" <> to_string(outbound["id"])

    Server.record_outbound(%{
      op: op,
      content: outbound["content"],
      text: outbound_text(outbound["content"]),
      target_external_id: outbound["target_external_id"],
      external_id: external_id,
      scope_id: reply_address["scope_id"],
      reply_address: reply_address
    })

    {:ok, delivery_outcome(op, external_id)}
  end

  @impl BullX.IMGateway.ChannelAdapter
  def consume_stream(_source, reply_address, stream_id, _opts) do
    Server.record_stream(%{
      stream_id: stream_id,
      scope_id: reply_address["scope_id"],
      reply_address: reply_address
    })

    :ok
  end

  @impl BullX.IMGateway.ChannelAdapter
  def capabilities do
    %{
      inbound_modes: [:mock],
      outbound_ops: [:send, :edit, :recall, :stream],
      content_kinds: [:text, :card, :control_notice, :progress_notice],
      group_message_modes: [:addressed_only, :observe_all, :engage_all]
    }
  end

  defp delivery_outcome("recall", external_id),
    do: %{"delivery_id" => external_id, "status" => "recalled", "warnings" => []}

  defp delivery_outcome(_op, external_id) do
    %{
      "delivery_id" => external_id,
      "primary_external_id" => external_id,
      "external_message_ids" => [external_id],
      "status" => "sent",
      "warnings" => []
    }
  end

  defp outbound_text(content) when is_list(content) do
    content
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp outbound_text(_content), do: ""

  defp block_text(%{"body" => %{"text" => text}}) when is_binary(text), do: text
  defp block_text(%{"text" => text}) when is_binary(text), do: text
  defp block_text(_block), do: ""
end

defmodule BullX.Integration.IMGateway.MockIM.Plugin do
  @moduledoc """
  Registers the mock channel adapter under extension id `"mock"`. Loaded into a
  throwaway `BullX.Plugins.Registry` per integration test via `Discovery.discover_app/2`
  (see `BullX.Integration.IMGateway.Case`); never enabled in dev/prod.
  """

  use BullX.Plugins.Plugin, app: :mock_im_plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.im_gateway.channel_adapter",
        id: "mock",
        module: BullX.Integration.IMGateway.MockIM.ChannelAdapter
      }
    ]
  end
end
