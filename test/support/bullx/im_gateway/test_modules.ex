defmodule BullX.IMGateway.TestingChannel do
  @moduledoc false

  def clear do
    Application.delete_env(:bullx, :im_gateway_test_delivery_gate)
    Application.delete_env(:bullx, :im_gateway_test_stream_error)
    :ok
  end
end

defmodule BullX.IMGateway.TestChannelAdapter do
  @moduledoc false

  @behaviour BullX.IMGateway.ChannelAdapter

  @impl BullX.IMGateway.ChannelAdapter
  def normalize_inbound(source, %{event: event}) do
    {:ok, Map.put(event, "source", source["source"])}
  end

  def normalize_inbound(_source, :ignore), do: :ignore
  def normalize_inbound(_source, _input), do: {:error, %{"kind" => "invalid_input"}}

  @impl BullX.IMGateway.ChannelAdapter
  def fetch_source("default"),
    do: {:ok, %{"id" => "default", "source" => "test://source/default"}}

  def fetch_source("other"),
    do: {:ok, %{"id" => "other", "source" => "test://source/other"}}

  def fetch_source(_source_id), do: {:error, :not_found}

  @impl BullX.IMGateway.ChannelAdapter
  def consume_stream(source, reply_address, stream_id, opts) do
    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_stream_consumed, source, reply_address, stream_id})
    end

    _opts = opts

    case Application.get_env(:bullx, :im_gateway_test_stream_error) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @impl BullX.IMGateway.ChannelAdapter
  def deliver(source, reply_address, %{"force_error" => true} = outbound, _opts) do
    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_delivery_failed, source, reply_address, outbound})
    end

    {:error, %{"kind" => "network", "message" => "test delivery failure", "details" => %{}}}
  end

  def deliver(source, reply_address, %{"op" => "recall"} = outbound, _opts) do
    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_delivered, source, reply_address, outbound})
    end

    {:ok,
     %{
       "delivery_id" => outbound["id"],
       "status" => "recalled",
       "warnings" => []
     }}
  end

  def deliver(source, reply_address, outbound, _opts) do
    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_delivered, source, reply_address, outbound})
    end

    primary_external_id = "external:" <> outbound["id"]

    {:ok,
     %{
       "delivery_id" => outbound["id"],
       "primary_external_id" => primary_external_id,
       "external_message_ids" => [primary_external_id],
       "status" => "sent",
       "warnings" => []
     }}
  end
end

defmodule BullX.IMGateway.TestAdapterPlugin do
  @moduledoc false

  use BullX.Plugins.Plugin, app: :im_gateway_test_plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.im_gateway.channel_adapter",
        id: "im_gateway_test",
        module: BullX.IMGateway.TestChannelAdapter
      }
    ]
  end
end
