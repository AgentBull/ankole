defmodule BullX.EventBus.StreamingOutputTest do
  use ExUnit.Case, async: false

  alias BullX.EventBus.StreamingOutput
  alias BullX.EventBus.StreamingOutput.Redis

  test "creates, appends, resumes, and finishes a Redis-backed stream" do
    target_session_id = BullX.Ext.gen_uuid_v7()
    target_session_entry_id = BullX.Ext.gen_uuid_v7()

    assert {:ok, stream_id} =
             StreamingOutput.create_stream(target_session_id, target_session_entry_id)

    assert {:ok, 0} = StreamingOutput.append_chunk(stream_id, "hello")
    assert {:ok, 1} = StreamingOutput.append_chunk(stream_id, " world")

    assert {:ok, %{status: :open, follow?: true, chunks: chunks}} =
             StreamingOutput.resume_stream(stream_id, -1)

    assert chunks == [%{offset: 0, chunk: "hello"}, %{offset: 1, chunk: " world"}]

    assert :ok = StreamingOutput.finish_stream(stream_id, :completed, "done")

    assert {:ok, %{status: :completed, follow?: false, chunks: [%{offset: 1, chunk: " world"}]}} =
             StreamingOutput.resume_stream(stream_id, 0)
  end

  test "rejects chunks over the configured byte limit" do
    assert {:ok, stream_id} = StreamingOutput.create_stream(BullX.Ext.gen_uuid_v7(), nil)
    oversized = String.duplicate("x", 1_025)

    assert {:error, :chunk_too_large} = StreamingOutput.append_chunk(stream_id, oversized)
  end

  test "follow_stream emits buffered chunks before terminal state" do
    assert {:ok, stream_id} = StreamingOutput.create_stream(BullX.Ext.gen_uuid_v7(), nil)
    assert {:ok, 0} = StreamingOutput.append_chunk(stream_id, "first")
    assert :ok = StreamingOutput.finish_stream(stream_id, :completed, "done")

    parent = self()

    assert :ok =
             StreamingOutput.follow_stream(stream_id, -1, fn event ->
               send(parent, {:stream_event, event})
             end)

    assert_receive {:stream_event, %{type: :chunk, offset: 0, chunk: "first"}}
  end

  test "finish_stream refreshes chunk retention with metadata retention" do
    assert {:ok, stream_id} = StreamingOutput.create_stream(BullX.Ext.gen_uuid_v7(), nil)
    assert {:ok, 0} = StreamingOutput.append_chunk(stream_id, "kept")

    assert {:ok, 1} = Redis.command(["PEXPIRE", chunks_key(stream_id), 1_000])
    assert :ok = StreamingOutput.finish_stream(stream_id, :completed, "done")
    assert {:ok, ttl_ms} = Redis.command(["PTTL", chunks_key(stream_id)])
    assert ttl_ms > 30_000
  end

  test "follow_stream catches chunks and terminal state written between replay and subscribe" do
    assert {:ok, stream_id} = StreamingOutput.create_stream(BullX.Ext.gen_uuid_v7(), nil)
    assert {:ok, 0} = StreamingOutput.append_chunk(stream_id, "first")

    parent = self()

    assert :ok =
             StreamingOutput.follow_stream(stream_id, -1, fn
               %{type: :chunk, offset: 0} = event ->
                 send(parent, {:stream_event, event})
                 assert {:ok, 1} = StreamingOutput.append_chunk(stream_id, "gap")
                 assert :ok = StreamingOutput.finish_stream(stream_id, :completed, "done")

               event ->
                 send(parent, {:stream_event, event})
             end)

    assert_receive {:stream_event, %{type: :chunk, offset: 0, chunk: "first"}}
    assert_receive {:stream_event, %{type: :chunk, offset: 1, chunk: "gap"}}
    assert_receive {:stream_event, %{type: :terminal, status: :completed}}
  end

  test "expired stream metadata is unavailable to resume" do
    assert {:ok, stream_id} = StreamingOutput.create_stream(BullX.Ext.gen_uuid_v7(), nil)
    assert {:ok, _reply} = Redis.command(["HSET", meta_key(stream_id), "status", "expired"])

    assert {:error, :unavailable} = StreamingOutput.resume_stream(stream_id, -1)
  end

  defp meta_key(stream_id), do: "bullx:stream:#{stream_id}:meta"
  defp chunks_key(stream_id), do: "bullx:stream:#{stream_id}:chunks"
end
