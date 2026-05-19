defmodule BullX.AIAgent.AmbientBatchTest do
  use ExUnit.Case, async: false

  alias BullX.AIAgent.{AmbientBatch, AmbientBatchWorker}

  test "enqueue refreshes the reply channel to the latest item in the batch window" do
    agent_principal_id = BullX.Ext.gen_uuid_v7()
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    batch_key = "#{agent_principal_id}:#{ambient_conversation_id}"

    on_exit(fn -> AmbientBatch.cleanup(batch_key) end)

    assert :ok =
             AmbientBatch.enqueue(batch(agent_principal_id, ambient_conversation_id, "first"))

    assert :ok =
             AmbientBatch.enqueue(batch(agent_principal_id, ambient_conversation_id, "second"))

    assert {:ok, meta, items} = AmbientBatch.take(batch_key)

    assert get_in(meta, ["reply_channel", "reply_to_external_id"]) == "second"
    assert Enum.map(items, & &1["message_id"]) == ["first", "second"]
  end

  test "enqueue can shorten an open batch due time without dropping items" do
    agent_principal_id = BullX.Ext.gen_uuid_v7()
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    batch_key = "#{agent_principal_id}:#{ambient_conversation_id}"

    on_exit(fn -> AmbientBatch.cleanup(batch_key) end)

    assert :ok =
             AmbientBatch.enqueue(batch(agent_principal_id, ambient_conversation_id, "first"))

    assert :ok =
             AmbientBatch.enqueue(
               batch(agent_principal_id, ambient_conversation_id, "second", %{
                 due_in_ms: AmbientBatch.fast_window_ms()
               })
             )

    assert {:ok, meta, items} = AmbientBatch.take(batch_key)

    assert meta["due_at"] - System.system_time(:millisecond) <= 5_000
    assert Enum.map(items, & &1["message_id"]) == ["first", "second"]
  end

  test "durable idempotency key is per processed ambient batch, not per conversation" do
    agent_principal_id = BullX.Ext.gen_uuid_v7()
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    meta = %{"batch_key" => "#{agent_principal_id}:#{ambient_conversation_id}"}

    first =
      AmbientBatchWorker.batch_idempotency_key(meta, [
        %{
          "message_id" => "provider-message-1",
          "text" => "美联储有人看吗",
          "sent_at" => "2026-05-20T00:00:00Z"
        }
      ])

    same_first =
      AmbientBatchWorker.batch_idempotency_key(meta, [
        %{
          "message_id" => "provider-message-1",
          "text" => "美联储有人看吗",
          "sent_at" => "2026-05-20T00:00:00Z"
        }
      ])

    second =
      AmbientBatchWorker.batch_idempotency_key(meta, [
        %{
          "message_id" => "provider-message-2",
          "text" => "生猪期货有人看吗",
          "sent_at" => "2026-05-20T00:01:00Z"
        }
      ])

    assert first == same_first
    assert first != second
    assert String.starts_with?(first, "ambient_batch:")
  end

  defp batch(agent_principal_id, ambient_conversation_id, message_id, extra \\ %{}) do
    Map.merge(
      %{
        agent_principal_id: agent_principal_id,
        ambient_conversation_id: ambient_conversation_id,
        scene_key: "feishu:group:oc_test",
        reply_channel: %{
          "adapter" => "feishu",
          "channel_id" => "main",
          "scope_id" => "oc_test",
          "scope_kind" => "group",
          "reply_to_external_id" => message_id
        },
        item: %{
          message_id: message_id,
          text: "ambient #{message_id}",
          sent_at: "2026-05-20T00:00:00Z"
        }
      },
      extra
    )
  end
end
