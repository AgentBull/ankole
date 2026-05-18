defmodule BullX.EventBus.ChannelAdapterTest do
  use ExUnit.Case, async: true

  alias BullX.EventBus.ChannelAdapter
  alias BullX.Plugins.{Discovery, Registry}

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
                 content: [%{"kind" => "text", "body" => %{"text" => "hello"}}],
                 channel: %{adapter: "test", id: "default"},
                 scope: %{id: "scope-1", thread_id: nil},
                 actor: %{id: "actor-1", display: nil, bot: false, principal_ref: nil}
               }
             })

    assert event["specversion"] == "1.0"
    assert event["data"]["channel"] == %{"adapter" => "test", "id" => "default"}
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

  defp valid_event(overrides) do
    data =
      Map.merge(
        %{
          "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}],
          "channel" => %{"adapter" => "eventbus_test", "id" => "default"},
          "scope" => %{"id" => "scope-1", "thread_id" => nil},
          "actor" => %{
            "id" => "actor-1",
            "display" => nil,
            "bot" => false,
            "principal_ref" => nil
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
