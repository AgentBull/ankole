defmodule BullX.EventBus.ChannelAdapterTest do
  use ExUnit.Case, async: false

  alias BullX.EventBus.ChannelAdapter
  alias BullX.EventBus.DeliveryCircuitBreaker
  alias BullX.Plugins.{Discovery, Registry}

  setup do
    DeliveryCircuitBreaker.reset()
    Application.put_env(:bullx, :event_bus_test_pid, self())

    on_exit(fn ->
      DeliveryCircuitBreaker.reset()
      Application.delete_env(:bullx, :event_bus_test_pid)
    end)
  end

  test "lists only enabled channel adapters and validates required callback" do
    {:ok, plugin} =
      Discovery.discover_app(:eventbus_test_plugin, modules: [BullX.EventBus.TestAdapterPlugin])

    name = :"adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["eventbus_test_plugin"], name: name}
    )

    assert {:ok, [adapter]} = ChannelAdapter.enabled_adapters(name)
    assert adapter.id == "eventbus_test"
    assert adapter.module == BullX.EventBus.TestChannelAdapter
  end

  test "build_cloud_event produces decoded string-keyed CloudEvents data" do
    assert {:ok, event} =
             ChannelAdapter.build_cloud_event(%{
               id: "provider-event-1",
               source: "test://source/default",
               type: "bullx.im.message.addressed",
               time: "2026-05-17T10:00:00Z",
               data: %{
                 content: [%{"type" => "text", "text" => "hello"}],
                 channel: %{adapter: "test", id: "default", kind: "dm"},
                 scope: %{id: "scope-1", thread_id: nil},
                 actor: %{external_account_id: "actor-1", display_name: nil, principal: nil}
               }
             })

    assert event["specversion"] == "1.0"
    assert event["data"]["channel"] == %{"adapter" => "test", "id" => "default", "kind" => "dm"}
    assert event["data"]["refs"] == []
    assert event["data"]["routing_facts"] == %{}
  end

  test "accept_inbound rejects normalized events from a different adapter id" do
    {:ok, plugin} =
      Discovery.discover_app(:eventbus_test_plugin, modules: [BullX.EventBus.TestAdapterPlugin])

    name = :"adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["eventbus_test_plugin"], name: name}
    )

    event = valid_event(%{"data" => %{"channel" => %{"adapter" => "other", "id" => "default"}}})

    assert {:error, %{"kind" => "adapter_id_mismatch"}} =
             ChannelAdapter.accept_inbound(
               "eventbus_test",
               %{"source" => "test://source/default"},
               %{event: event},
               registry: name
             )
  end

  test "deliver opens a source-scoped circuit after repeated failures" do
    {:ok, plugin} =
      Discovery.discover_app(:eventbus_test_plugin, modules: [BullX.EventBus.TestAdapterPlugin])

    name = :"adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["eventbus_test_plugin"], name: name}
    )

    reply_channel = %{"adapter" => "eventbus_test", "channel_id" => "default"}
    opts = [registry: name, delivery_circuit_breaker: [failure_threshold: 2, open_ms: 1_000]]

    assert {:error, %{"kind" => "network"}} =
             ChannelAdapter.deliver(
               reply_channel,
               %{"id" => "delivery-1", "force_error" => true},
               opts
             )

    assert_receive {:event_bus_adapter_delivery_failed, _source, _reply_channel,
                    %{"id" => "delivery-1"}}

    assert {:error, %{"kind" => "network"}} =
             ChannelAdapter.deliver(
               reply_channel,
               %{"id" => "delivery-2", "force_error" => true},
               opts
             )

    assert_receive {:event_bus_adapter_delivery_failed, _source, _reply_channel,
                    %{"id" => "delivery-2"}}

    assert {:error, %{"kind" => "circuit_open"}} =
             ChannelAdapter.deliver(
               reply_channel,
               %{"id" => "delivery-3", "force_error" => true},
               opts
             )

    refute_receive {:event_bus_adapter_delivery_failed, _source, _reply_channel,
                    %{"id" => "delivery-3"}}

    other_reply_channel = %{"adapter" => "eventbus_test", "channel_id" => "other"}

    assert {:ok, %{"status" => "sent"}} =
             ChannelAdapter.deliver(other_reply_channel, %{"id" => "delivery-4"}, opts)
  end

  test "delivery circuit half-open success closes the circuit" do
    {:ok, spy} =
      BullX.BusSpy.start_link(
        events: [[:bullx, :event_bus, :adapter, :delivery_circuit, :opened]]
      )

    key = {"eventbus_test", "half-open"}
    opts = [failure_threshold: 1, open_ms: 1]

    assert {:error, %{"kind" => "network"}} =
             DeliveryCircuitBreaker.run(
               key,
               fn ->
                 {:error, %{"kind" => "network", "message" => "fail", "details" => %{}}}
               end,
               opts
             )

    assert {:ok, %{metadata: %{adapter_id: "eventbus_test", source_id: "half-open"}}} =
             BullX.BusSpy.wait_for_event(
               spy,
               [:bullx, :event_bus, :adapter, :delivery_circuit, :opened],
               100
             )

    assert {:error, %{"kind" => "circuit_open"}} =
             DeliveryCircuitBreaker.run(key, fn -> {:ok, %{}} end, opts)

    Process.sleep(2)

    assert {:ok, %{status: :sent}} =
             DeliveryCircuitBreaker.run(key, fn -> {:ok, %{status: :sent}} end, opts)

    assert {:ok, %{status: :sent_again}} =
             DeliveryCircuitBreaker.run(key, fn -> {:ok, %{status: :sent_again}} end, opts)
  end

  defp valid_event(overrides) do
    data =
      Map.merge(
        %{
          "content" => [%{"type" => "text", "text" => "hello"}],
          "channel" => %{"adapter" => "eventbus_test", "id" => "default", "kind" => "dm"},
          "scope" => %{"id" => "scope-1", "thread_id" => nil},
          "actor" => %{
            "external_account_id" => "actor-1",
            "display_name" => nil,
            "principal" => nil
          },
          "refs" => [],
          "reply_channel" => nil,
          "routing_facts" => %{},
          "raw_ref" => nil
        },
        get_in(overrides, ["data"]) || %{}
      )

    %{
      "specversion" => "1.0",
      "id" => "provider-event-1",
      "source" => "test://source/default",
      "type" => "bullx.im.message.addressed",
      "time" => "2026-05-17T10:00:00Z",
      "datacontenttype" => "application/json",
      "data" => data
    }
    |> Map.merge(Map.delete(overrides, "data"))
  end
end
