defmodule BullX.EventBus.TestTarget do
  @moduledoc false

  @behaviour BullX.EventBus.Target

  @impl BullX.EventBus.Target
  def handle_event(invocation, entry) do
    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_target_called, invocation, entry})
    end

    invocation.close.()
    :ok
  end
end

defmodule BullX.EventBus.TestChannelAdapter do
  @moduledoc false

  @behaviour BullX.EventBus.ChannelAdapter

  @impl BullX.EventBus.ChannelAdapter
  def normalize_inbound(source, %{event: event}) do
    {:ok, Map.put(event, "source", source["source"])}
  end

  def normalize_inbound(_source, :ignore), do: :ignore
  def normalize_inbound(_source, _input), do: {:error, %{"kind" => "invalid_input"}}

  @impl BullX.EventBus.ChannelAdapter
  def fetch_source("default"),
    do: {:ok, %{"id" => "default", "source" => "test://source/default"}}

  def fetch_source("other"),
    do: {:ok, %{"id" => "other", "source" => "test://source/other"}}

  def fetch_source(_source_id), do: {:error, :not_found}

  @impl BullX.EventBus.ChannelAdapter
  def deliver(source, reply_channel, %{"force_error" => true} = outbound, _opts) do
    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_adapter_delivery_failed, source, reply_channel, outbound})
    end

    {:error, %{"kind" => "network", "message" => "test delivery failure", "details" => %{}}}
  end

  def deliver(source, reply_channel, outbound, _opts) do
    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_adapter_delivered, source, reply_channel, outbound})
    end

    {:ok,
     %{
       "delivery_id" => outbound["id"],
       "status" => "sent",
       "warnings" => []
     }}
  end
end

defmodule BullX.EventBus.TestAdapterPlugin do
  @moduledoc false

  use BullX.Plugins.Plugin, app: :eventbus_test_plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "eventbus_test",
        module: BullX.EventBus.TestChannelAdapter
      }
    ]
  end
end
