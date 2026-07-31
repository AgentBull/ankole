defmodule Ankole.Plugins.WeComAdapterAIStreamTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.WeComAdapter
  alias Ankole.Plugins.WeComAdapter.AIStream
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

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

      {:reply, {:ok, %{"headers" => %{"req_id" => req_id}, "errcode" => 0, "body" => %{}}},
       parent}
    end
  end

  @channel_id "wecom:wr-stream-1"

  defp setup_stream_binding(channel_metadata) do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(WeComAdapter.app_config_patterns())

    config_id = "wecom-stream-#{System.unique_integer([:positive])}"
    bot_id = "bot-#{System.unique_integer([:positive])}"
    config = %{"botId" => bot_id, "secret" => "secret"}

    {:ok, _config} = AppConfigure.put_global_by_key(Config.chat_config_key(config_id), config)

    %{principal: agent} = agent_fixture()

    {:ok, _binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "wecom-stream",
        adapter: "wecom",
        config_ref: "app-config://#{Config.chat_config_key(config_id)}",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        "wecom-stream",
        group_entry(%{
          source_event_id: unique_uid("wecom-event"),
          source_entry_id: unique_uid("wecom-trigger"),
          signal_channel_id: @channel_id,
          channel: %{kind: :im_group, reply_mode: :channel, name: nil},
          explicit: true
        })
      )

    channel = Repo.get!(Channel, @channel_id)

    channel
    |> Channel.changeset(%{metadata: Map.merge(channel.metadata, channel_metadata)})
    |> Repo.update!()

    registry = Ankole.Plugins.WeComAdapter.ConnectionRegistry

    if is_nil(Process.whereis(registry)) do
      start_supervised!({Registry, keys: :unique, name: registry})
    end

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

  defp fresh(event), do: Repo.get!(ActorEvent, event.id)

  defp request(event, presentation, mode) do
    %Request{actor_event: event, presentation: presentation, mode: mode}
  end

  test "open streams the first page bound to the channel's respond anchor and checkpoints it" do
    event = setup_stream_binding(fresh_anchor_metadata())

    assert {:ok, result} =
             AIStream.open(request(event, working("hello from the agent"), :working))

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

    assert {:ok, _open} = AIStream.open(request(event, working("partial"), :working))
    assert_receive {:bot_frame, "aibot_respond_msg", _req, _open_body}

    assert {:ok, result} =
             AIStream.finalize(request(fresh(event), completed("final answer"), :terminal))

    assert_receive {:bot_frame, "aibot_respond_msg", "req-stream-1", body}
    assert body["stream"]["finish"] == true
    assert body["stream"]["content"] =~ "final answer"
    refute body["stream"]["content"] =~ "▌"

    checkpoint = result.reply_preview_checkpoint
    assert checkpoint["streaming_state"] == "closed"
    assert [%{"sealed" => true}] = checkpoint["pages"]
  end

  test "an answer beyond the page budget seals earlier pages and continues on new stream ids" do
    event = setup_stream_binding(fresh_anchor_metadata())

    long_answer = String.duplicate("内容行内容行内容行\n", 1_500)
    assert byte_size(long_answer) > 14_000

    assert {:ok, result} = AIStream.finalize(request(event, completed(long_answer), :terminal))

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

    assert {:ok, _open} = AIStream.open(request(event, working("first page text"), :working))
    assert_receive {:bot_frame, "aibot_respond_msg", _req, _body}

    # Age the open page past the 9-minute axis and clear the write throttle.
    stale = DateTime.utc_now() |> DateTime.add(-10 * 60) |> DateTime.to_iso8601()
    stored = fresh(event)
    checkpoint = stored.reply_preview_checkpoint
    [page] = checkpoint["pages"]

    aged =
      checkpoint
      |> Map.put("pages", [Map.put(page, "opened_at", stale)])
      |> Map.delete("last_write_at")

    {:ok, _event} = Ankole.SignalsGateway.Actors.put_reply_preview_checkpoint(event.id, aged)

    assert {:ok, result} =
             AIStream.update(
               request(fresh(event), working("first page text plus growth"), :working)
             )

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

    assert {:ok, _open} = AIStream.open(request(event, working("one"), :working))
    assert_receive {:bot_frame, _cmd, _req, _body}

    assert {:ok, _update} = AIStream.update(request(fresh(event), working("one two"), :working))
    refute_receive {:bot_frame, _cmd2, _req2, _body2}, 100

    assert {:ok, _final} =
             AIStream.finalize(request(fresh(event), completed("one two three"), :terminal))

    assert_receive {:bot_frame, "aibot_respond_msg", _req3, body}
    assert body["stream"]["finish"] == true
    assert body["stream"]["content"] =~ "one two three"
  end

  test "without a respond anchor working syncs degrade and the terminal falls back to proactive markdown" do
    event = setup_stream_binding(%{})

    assert {:error, {:cardkit_plain_text_fallback, :no_reply_anchor}} =
             AIStream.open(request(event, working("hello"), :working))

    refute_receive {:bot_frame, _cmd, _req, _body}, 50

    assert {:ok, result} =
             AIStream.finalize(request(fresh(event), completed("final via send"), :terminal))

    assert_receive {:bot_frame, "aibot_send_msg", _req, body}
    assert body["msgtype"] == "markdown"
    assert body["markdown"]["content"] == "final via send"
    assert body["chat_type"] == 2

    checkpoint = result.reply_preview_checkpoint
    assert checkpoint["degraded"] == true
    assert [%{"index" => 0, "source" => "final via send"}] = checkpoint["plain_chunks"]

    # A retry of the terminal outbox delivery re-sends nothing.
    assert {:ok, _retry} =
             AIStream.finalize(request(fresh(event), completed("final via send"), :terminal))

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
