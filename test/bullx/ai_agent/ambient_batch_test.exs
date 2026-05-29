defmodule BullX.AIAgent.AmbientBatchTest do
  use ExUnit.Case, async: false

  alias BullX.AIAgent.{AmbientBatch, AmbientBatchWorker}

  test "enqueue refreshes the reply address to the latest item in the batch window" do
    agent_uid = "ambient-batch-agent-1"
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    batch_key = "#{agent_uid}:#{ambient_conversation_id}"

    on_exit(fn -> AmbientBatch.cleanup(batch_key) end)

    assert :ok =
             AmbientBatch.enqueue(batch(agent_uid, ambient_conversation_id, "first"))

    assert :ok =
             AmbientBatch.enqueue(batch(agent_uid, ambient_conversation_id, "second"))

    assert {:ok, meta, items} = AmbientBatch.take(batch_key)

    assert get_in(meta, ["reply_address", "reply_to_external_id"]) == "second"
    assert Enum.map(items, & &1["message_id"]) == ["first", "second"]
  end

  test "enqueue can shorten an open batch due time without dropping items" do
    agent_uid = "ambient-batch-agent-2"
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    batch_key = "#{agent_uid}:#{ambient_conversation_id}"

    on_exit(fn -> AmbientBatch.cleanup(batch_key) end)

    assert :ok =
             AmbientBatch.enqueue(batch(agent_uid, ambient_conversation_id, "first"))

    assert :ok =
             AmbientBatch.enqueue(
               batch(agent_uid, ambient_conversation_id, "second", %{
                 due_in_ms: AmbientBatch.fast_window_ms()
               })
             )

    assert {:ok, meta, items} = AmbientBatch.take(batch_key)

    assert meta["due_at"] - System.system_time(:millisecond) <= 5_000
    assert Enum.map(items, & &1["message_id"]) == ["first", "second"]
  end

  test "update_item rewrites a pending batch item" do
    agent_uid = "ambient-batch-agent-3"
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    batch_key = "#{agent_uid}:#{ambient_conversation_id}"

    on_exit(fn -> AmbientBatch.cleanup(batch_key) end)

    assert :ok =
             AmbientBatch.enqueue(batch(agent_uid, ambient_conversation_id, "first"))

    assert :ok =
             AmbientBatch.update_item(
               agent_uid,
               ambient_conversation_id,
               "first",
               "edited ambient"
             )

    assert {:ok, _meta, [%{"text" => "edited ambient"}]} = AmbientBatch.take(batch_key)
  end

  test "remove_item drops pending item and cleans up an empty batch" do
    agent_uid = "ambient-batch-agent-4"
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    batch_key = "#{agent_uid}:#{ambient_conversation_id}"

    on_exit(fn -> AmbientBatch.cleanup(batch_key) end)

    assert :ok =
             AmbientBatch.enqueue(batch(agent_uid, ambient_conversation_id, "first"))

    assert :ok = AmbientBatch.remove_item(agent_uid, ambient_conversation_id, "first")
    assert {:error, :missing} = AmbientBatch.take(batch_key)
  end

  test "durable idempotency key is per processed ambient batch, not per conversation" do
    agent_uid = "ambient-batch-agent-5"
    ambient_conversation_id = BullX.Ext.gen_uuid_v7()
    meta = %{"batch_key" => "#{agent_uid}:#{ambient_conversation_id}"}

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

  defp batch(agent_uid, ambient_conversation_id, message_id, extra \\ %{}) do
    Map.merge(
      %{
        agent_uid: agent_uid,
        ambient_conversation_id: ambient_conversation_id,
        scene_key: "feishu:group:oc_test",
        reply_address: %{
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
