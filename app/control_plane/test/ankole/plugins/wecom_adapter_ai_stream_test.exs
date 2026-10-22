defmodule Ankole.Plugins.WeComAdapterAIStreamTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.WeComAdapter.AIStream
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Repo

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request

  defmodule FakeBotClient do
    use GenServer

    def start_link(key, parent) do
      GenServer.start_link(__MODULE__, parent, name: ConnectionOwner.client_name(key))
    end

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call({:send_frame, cmd, req_id, body}, _from, parent) do
      send(parent, {:bot_frame, cmd, req_id, body})

      {:reply,
       {:ok,
        %{
          "headers" => %{"req_id" => req_id},
          "errcode" => 0,
          "body" => %{"msgid" => "provider-#{req_id}"}
        }}, parent}
    end
  end

  @channel_id "wecom:wr-stream-1"

  defp setup_stream_binding(channel_metadata) do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()

    config_id = "wecom-stream-#{System.unique_integer([:positive])}"
    bot_id = "bot-#{System.unique_integer([:positive])}"
    config = %{"botId" => bot_id, "secret" => "secret"}

    {:ok, _config} =
      AppConfigure.put_global_by_key("signals.wecom.bindings." <> config_id, config)

    %{principal: agent} = agent_fixture()

    {:ok, _binding} =
      Ankole.SignalsFixtures.raw_binding_fixture(%{
        agent_uid: agent.uid,
        name: "wecom-stream",
        adapter: "wecom",
        config_ref: "app-config://#{"signals.wecom.bindings." <> config_id}",
        filters: %{},
        unaddressed_group_message_policy: :ignore,
        unmatched_sender_policy: :create_standalone
      })

    %{signal: event} =
      emit_addressed_signal(
        agent.uid,
        "wecom-stream",
        group_entry(%{
          source_event_id: unique_uid("wecom-event"),
          provider_message_id: unique_uid("wecom-trigger"),
          provider_conversation_id: @channel_id,
          channel: %{kind: :im_group, reply_mode: :channel, name: nil},
          explicit: true
        })
      )

    channel = Repo.get_by!(Conversation, provider_conversation_id: @channel_id)

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(channel, :put_metadata, %{
                 metadata: Map.merge(channel.metadata, channel_metadata)
               })
             end)

    key = Config.connection_key(config)

    start_supervised!(%{
      id: {:fake_bot, key},
      start: {FakeBotClient, :start_link, [key, self()]}
    })

    event
  end

  defp fresh_anchor_metadata do
    %{
      "last_req_id" => "req-stream-1",
      "last_req_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp working(answer) do
    ReplyPresentation.new() |> ReplyPresentation.append_answer(answer)
  end

  defp completed(answer) do
    ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
  end

  defp fresh(event), do: Repo.get!(Signal, event.id)

  defp request(event, presentation, mode) do
    %Request{signal: event, presentation: presentation, mode: mode}
  end

  for operation <- [:update, :finalize] do
    defp unquote(operation)(request) do
      {:ok, adapter} = PreviewAdapter.from_module(AIStream)
      apply(PreviewAdapter, unquote(operation), [adapter, request])
    end
  end

  test "open streams the first page bound to the channel's respond anchor and checkpoints it" do
    event = setup_stream_binding(fresh_anchor_metadata())

    assert {:ok, result} =
             update(request(event, working("hello from the agent"), :working))

    assert_receive {:bot_frame, "aibot_respond_msg", "req-stream-1", body}
    assert body["msgtype"] == "stream"
    assert body["stream"]["id"] == "ankole:#{event.id}:0"
    assert body["stream"]["finish"] == false
    assert body["stream"]["content"] =~ "hello from the agent"
    assert body["stream"]["content"] =~ "▌"

    checkpoint = result.reply_preview_checkpoint
    assert checkpoint["req_id"] == "req-stream-1"
    assert checkpoint["streaming_state"] == "open"
    assert [%{"index" => 0, "sealed" => false}] = checkpoint["pages"]
  end

  test "finalize refreshes the full snapshot and seals the stream without the status line" do
    event = setup_stream_binding(fresh_anchor_metadata())

    assert {:ok, _open} = update(request(event, working("partial"), :working))
    assert_receive {:bot_frame, "aibot_respond_msg", _req, _open_body}

    assert {:ok, result} =
             finalize(request(fresh(event), completed("final answer"), :terminal))

    assert_receive {:bot_frame, "aibot_respond_msg", "req-stream-1", body}
    assert body["stream"]["finish"] == true
    assert body["stream"]["content"] =~ "final answer"
    refute body["stream"]["content"] =~ "▌"

    checkpoint = result.reply_preview_checkpoint
    assert checkpoint["streaming_state"] == "closed"
    assert [%{"sealed" => true}] = checkpoint["pages"]
  end

  test "a continued turn seals the old stream with the handoff status" do
    event = setup_stream_binding(fresh_anchor_metadata())

    continued = working("旧卡片答案") |> ReplyPresentation.continued()

    assert {:ok, result} = finalize(request(event, continued, :terminal))

    assert_receive {:bot_frame, "aibot_respond_msg", "req-stream-1", body}
    assert body["stream"]["finish"] == true
    assert body["stream"]["content"] =~ "已暂停，后续处理续接于下一张卡片"
    assert body["stream"]["content"] =~ "旧卡片答案"

    assert result.reply_preview_checkpoint["presentation"][
             "state"
           ] == "continued"
  end

  test "an answer beyond the page budget seals earlier pages and continues on new stream ids" do
    event = setup_stream_binding(fresh_anchor_metadata())

    long_answer = String.duplicate("内容行内容行内容行\n", 1_500)
    assert byte_size(long_answer) > 14_000

    assert {:ok, result} = finalize(request(event, completed(long_answer), :terminal))

    frames = collect_frames([])
    assert length(frames) >= 2

    stream_ids = Enum.map(frames, fn {_cmd, _req, body} -> body["stream"]["id"] end)
    assert stream_ids == Enum.uniq(stream_ids)

    assert Enum.all?(frames, fn {_cmd, _req, body} -> body["stream"]["finish"] == true end)

    pages = result.reply_preview_checkpoint["pages"]
    assert length(pages) == length(frames)
    assert Enum.map_join(pages, "", & &1["source"]) == long_answer
  end

  test "an over-age open page is frozen at its written source and the chain continues" do
    event = setup_stream_binding(fresh_anchor_metadata())

    assert {:ok, _open} = update(request(event, working("first page text"), :working))
    assert_receive {:bot_frame, "aibot_respond_msg", _req, _body}

    # Age the open page past the 9-minute axis and clear the write throttle.
    stale = DateTime.utc_now() |> DateTime.add(-10 * 60) |> DateTime.to_iso8601()
    stored = fresh(event)

    checkpoint =
      PreviewAdapter.adapter_checkpoint(
        Ankole.Conversations.Delivery.PreviewState.get(stored).checkpoint
      )

    [page] = checkpoint["pages"]

    aged =
      checkpoint
      |> Map.put("pages", [Map.put(page, "opened_at", stale)])
      |> Map.delete("last_write_at")

    {:ok, _event} = PreviewState.put_checkpoint(event.id, aged)

    assert {:ok, result} =
             update(request(fresh(event), working("first page text plus growth"), :working))

    frames = collect_frames([])

    seal_frame =
      Enum.find(frames, fn {_cmd, _req, body} ->
        body["stream"]["id"] == "ankole:#{event.id}:0"
      end)

    continuation =
      Enum.find(frames, fn {_cmd, _req, body} ->
        body["stream"]["id"] == "ankole:#{event.id}:1"
      end)

    assert {_cmd, _req, seal_body} = seal_frame
    assert seal_body["stream"]["finish"] == true
    assert seal_body["stream"]["content"] =~ "first page text"

    assert {_cmd2, _req2, cont_body} = continuation
    assert cont_body["stream"]["finish"] == false
    assert cont_body["stream"]["content"] =~ "plus growth"

    pages = result.reply_preview_checkpoint["pages"]

    assert [%{"sealed" => true, "index" => 0}, %{"sealed" => false, "index" => 1}] =
             Enum.map(pages, &Map.take(&1, ["sealed", "index"]))
  end

  test "a rapid second update is throttled and a later finalize still flushes" do
    event = setup_stream_binding(fresh_anchor_metadata())

    assert {:ok, _open} = update(request(event, working("one"), :working))
    assert_receive {:bot_frame, _cmd, _req, _body}

    assert {:ok, _update} = update(request(fresh(event), working("one two"), :working))
    refute_receive {:bot_frame, _cmd2, _req2, _body2}, 100

    assert {:ok, _final} =
             finalize(request(fresh(event), completed("one two three"), :terminal))

    assert_receive {:bot_frame, "aibot_respond_msg", _req3, body}
    assert body["stream"]["finish"] == true
    assert body["stream"]["content"] =~ "one two three"
  end

  test "rollover freezes only confirmed text after a throttled update" do
    event = setup_stream_binding(fresh_anchor_metadata())

    assert {:ok, _open} = update(request(event, working("confirmed text"), :working))
    assert_receive {:bot_frame, "aibot_respond_msg", _req, _body}

    assert {:ok, skipped} =
             update(request(fresh(event), working("confirmed text pending growth"), :working))

    refute_receive {:bot_frame, _cmd, _req, _body}, 100

    assert [%{"source" => "confirmed text"}] =
             skipped.reply_preview_checkpoint["pages"]

    checkpoint =
      PreviewAdapter.adapter_checkpoint(
        Ankole.Conversations.Delivery.PreviewState.get(fresh(event)).checkpoint
      )

    [page] = checkpoint["pages"]
    stale = DateTime.utc_now() |> DateTime.add(-10 * 60) |> DateTime.to_iso8601()

    {:ok, _event} =
      PreviewState.put_checkpoint(
        event.id,
        Map.put(checkpoint, "pages", [Map.put(page, "opened_at", stale)])
      )

    assert {:ok, result} =
             update(request(fresh(event), working("confirmed text pending growth"), :working))

    assert_receive {:bot_frame, "aibot_respond_msg", _req, seal}
    assert seal["stream"]["id"] == "ankole:#{event.id}:0"
    assert seal["stream"]["finish"] == true
    refute seal["stream"]["content"] =~ "pending growth"

    assert_receive {:bot_frame, "aibot_respond_msg", _req, continuation}
    assert continuation["stream"]["id"] == "ankole:#{event.id}:1"
    assert continuation["stream"]["content"] =~ "pending growth"

    assert [%{"source" => "confirmed text"}, %{"source" => " pending growth"}] =
             result.reply_preview_checkpoint["pages"]
  end

  test "growth opens a new tail page even inside the refresh throttle" do
    event = setup_stream_binding(fresh_anchor_metadata())
    first = String.duplicate("x", 13_900)
    answer = first <> String.duplicate("y", 1_000)

    assert {:ok, _open} = update(request(event, working(first), :working))
    assert_receive {:bot_frame, "aibot_respond_msg", _req, _body}

    assert {:ok, result} = update(request(fresh(event), working(answer), :working))
    frames = collect_frames([])
    assert length(frames) == 2

    [first_page, tail_page] =
      result.reply_preview_checkpoint["pages"]

    assert tail_page["source"] =~ "y"

    assert Enum.any?(frames, fn {_cmd, _req, body} ->
             body["stream"]["id"] == "ankole:#{event.id}:1" and
               body["stream"]["finish"] == false and
               String.ends_with?(body["stream"]["content"], tail_page["source"])
           end)

    assert Enum.any?(frames, fn {_cmd, _req, body} ->
             body["stream"]["id"] == "ankole:#{event.id}:0" and
               body["stream"]["finish"] == true and
               body["stream"]["content"] == first_page["source"] <> "\n\n*（续下一条）*"
           end)

    assert Enum.map_join(
             result.reply_preview_checkpoint["pages"],
             & &1["source"]
           ) == answer
  end

  test "without a respond anchor working syncs degrade and the terminal falls back to proactive markdown" do
    event = setup_stream_binding(%{})

    assert {:error, {:degraded, :plain_text, :no_reply_anchor}} =
             update(request(event, working("hello"), :working))

    refute_receive {:bot_frame, _cmd, _req, _body}, 50

    assert {:ok, result} =
             finalize(request(fresh(event), completed("final via send"), :terminal))

    assert_receive {:bot_frame, "aibot_send_msg", _req, body}
    assert body["msgtype"] == "markdown"
    assert body["markdown"]["content"] == "final via send"
    assert body["chat_type"] == 2

    checkpoint = result.reply_preview_checkpoint
    assert checkpoint["degraded"] == true
    assert [%{"index" => 0, "source" => "final via send"}] = checkpoint["plain_chunks"]

    # A retry of the terminal intent delivery re-sends nothing.
    assert {:ok, _retry} =
             finalize(request(fresh(event), completed("final via send"), :terminal))

    refute_receive {:bot_frame, "aibot_send_msg", _req2, _body2}, 50
  end

  defp collect_frames(acc) do
    receive do
      {:bot_frame, cmd, req, body} -> collect_frames(acc ++ [{cmd, req, body}])
    after
      150 -> acc
    end
  end
end
