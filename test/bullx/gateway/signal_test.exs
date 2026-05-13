defmodule BullX.Gateway.SignalTest do
  use ExUnit.Case, async: true

  alias BullX.Gateway.Signal

  test "dump and load use flat CloudEvents JSON event format" do
    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.inbound.received",
        "time" => "2026-05-13T00:00:00Z",
        "datacontenttype" => "application/json",
        "data" => %{"content" => []},
        "bullxoccurkey" => "feishu:event_1",
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    dumped = Signal.dump(signal)

    refute Map.has_key?(dumped, "extensions")
    assert dumped["specversion"] == "1.0"
    assert dumped["bullxoccurkey"] == "feishu:event_1"
    assert {:ok, loaded} = Signal.load(dumped)
    assert Signal.dump(loaded) == dumped
  end

  test "load rejects nested extensions maps" do
    assert {:error, :nested_extensions} =
             Signal.load(%{
               "id" => BullX.Ext.gen_uuid_v7(),
               "source" => "bullx://gateway/feishu/main",
               "type" => "com.agentbull.x.inbound.received",
               "time" => "2026-05-13T00:00:00Z",
               "data" => %{},
               "extensions" => %{"bullxoccurkey" => "bad"}
             })
  end

  test "gateway carrier types require configured source extensions" do
    assert {:error, :missing_gateway_extensions} =
             Signal.new(%{
               "id" => BullX.Ext.gen_uuid_v7(),
               "source" => "bullx://gateway/feishu/main",
               "type" => "com.agentbull.x.inbound.received",
               "time" => "2026-05-13T00:00:00Z",
               "data" => %{},
               "bullxoccurkey" => "feishu:event_1"
             })
  end
end
