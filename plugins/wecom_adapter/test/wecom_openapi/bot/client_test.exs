defmodule WeComOpenAPI.Bot.ClientTest do
  use ExUnit.Case, async: false

  alias WeComOpenAPI.Bot
  alias WeComOpenAPI.Bot.{Client, Dispatcher}
  alias WeComOpenAPI.Error
  alias WeComOpenAPI.FakeWsServer

  test "start_link validates the dispatcher type" do
    assert_raise ArgumentError, ~r/Dispatcher/, fn ->
      Client.start_link(bot_id: "bot", secret: "secret", dispatcher: :bad)
    end
  end

  test "connects to the WeCom gateway when its HTTP/1 upgrade headers are case-sensitive" do
    parent = self()
    {server, port} = FakeWsServer.start(parent, require_wecom_header_case: true)
    on_exit(fn -> send(server, :close) end)

    pid =
      start_supervised!(
        {Client,
         [
           bot_id: "bot-1",
           secret: "secret-1",
           dispatcher: Dispatcher.new(),
           ws_url: "ws://127.0.0.1:#{port}/",
           auto_reconnect: false
         ]},
        restart: :temporary
      )

    assert_receive {:ws_upgraded, ^server}, 2_000
    assert_receive {:client_frame, %{"cmd" => "aibot_subscribe"} = auth}, 2_000

    send(
      server,
      {:push,
       %{
         "headers" => %{"req_id" => auth["headers"]["req_id"]},
         "errcode" => 0,
         "errmsg" => "ok"
       }}
    )

    wait_until(fn -> Client.status(pid) == :connected end)
  end

  defp start_connected(dispatcher, extra_opts \\ []) do
    parent = self()
    {server, port} = FakeWsServer.start(parent)
    on_exit(fn -> send(server, :close) end)

    opts =
      Keyword.merge(
        [
          bot_id: "bot-1",
          secret: "secret-1",
          dispatcher: dispatcher,
          ws_url: "ws://127.0.0.1:#{port}/",
          auto_reconnect: false
        ],
        extra_opts
      )

    pid = start_supervised!({Client, opts}, restart: :temporary)

    assert_receive {:ws_upgraded, ^server}, 2_000

    # Auth frame carries the credentials; ack it to reach :connected.
    assert_receive {:client_frame, %{"cmd" => "aibot_subscribe"} = auth}, 2_000
    assert auth["body"] == %{"bot_id" => "bot-1", "secret" => "secret-1"}
    auth_req_id = auth["headers"]["req_id"]
    assert String.starts_with?(auth_req_id, "aibot_subscribe_")

    send(
      server,
      {:push, %{"headers" => %{"req_id" => auth_req_id}, "errcode" => 0, "errmsg" => "ok"}}
    )

    wait_until(fn -> Client.status(pid) == :connected end)
    {pid, server}
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  test "authenticates, dispatches message callbacks, and serializes replies per req_id" do
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_message(fn event ->
        send(parent, {:dispatched, event.msgid, event.req_id})
        :ok
      end)

    {pid, server} = start_connected(dispatcher)

    # Inbound message callback reaches the dispatcher with routing fields.
    send(
      server,
      {:push,
       %{
         "cmd" => "aibot_msg_callback",
         "headers" => %{"req_id" => "req-in-1"},
         "body" => %{
           "msgid" => "msg-1",
           "chattype" => "single",
           "from" => %{"userid" => "alice"},
           "msgtype" => "text",
           "text" => %{"content" => "hi"}
         }
       }}
    )

    assert_receive {:dispatched, "msg-1", "req-in-1"}, 2_000

    # Two replies to the same req_id: the second frame goes out only after the
    # first ack (acks are attributable only by req_id).
    task_one = Task.async(fn -> Bot.reply_markdown(pid, "req-in-1", "first") end)
    assert_receive {:client_frame, %{"cmd" => "aibot_respond_msg"} = first}, 2_000
    assert first["headers"]["req_id"] == "req-in-1"
    assert first["body"]["markdown"]["content"] == "first"

    task_two = Task.async(fn -> Bot.reply_markdown(pid, "req-in-1", "second") end)
    refute_receive {:client_frame, %{"cmd" => "aibot_respond_msg"}}, 200

    send(
      server,
      {:push, %{"headers" => %{"req_id" => "req-in-1"}, "errcode" => 0, "errmsg" => "ok"}}
    )

    assert {:ok, _ack} = Task.await(task_one, 2_000)

    assert_receive {:client_frame, %{"cmd" => "aibot_respond_msg"} = second}, 2_000
    assert second["body"]["markdown"]["content"] == "second"

    send(
      server,
      {:push, %{"headers" => %{"req_id" => "req-in-1"}, "errcode" => 0, "errmsg" => "ok"}}
    )

    assert {:ok, _ack} = Task.await(task_two, 2_000)
  end

  test "an ACK timeout distinguishes queued replies from other requests already sent" do
    {pid, _server} = start_connected(Dispatcher.new(), ack_timeout_ms: 80)
    monitor = Process.monitor(pid)

    first = Task.async(fn -> Bot.reply_markdown(pid, "same-request", "first") end)
    assert_receive {:client_frame, %{"cmd" => "aibot_respond_msg"}}, 2_000
    second = Task.async(fn -> Bot.reply_markdown(pid, "same-request", "second") end)

    wait_until(fn ->
      match?({:connected, %{reply_queues: %{"same-request" => _}}}, :sys.get_state(pid))
    end)

    pending = Task.async(fn -> Bot.send_markdown(pid, "chat-1", 2, "already sent") end)
    assert_receive {:client_frame, %{"cmd" => "aibot_send_msg"}}, 2_000
    assert {:error, %Error{reason: :ack_timeout}} = Task.await(first, 2_000)
    assert {:error, %Error{reason: :not_connected}} = Task.await(second, 2_000)
    assert {:error, %Error{reason: :transport, raw: :ack_timeout}} = Task.await(pending, 2_000)
    refute_receive {:client_frame, %{"cmd" => "aibot_respond_msg"}}, 100
    assert_receive {:DOWN, ^monitor, :process, ^pid, {:shutdown, :ack_timeout}}, 2_000
  end

  test "authenticating state_timeout stops when auto_reconnect is disabled" do
    parent = self()
    {server, port} = FakeWsServer.start(parent)
    on_exit(fn -> send(server, :close) end)

    pid =
      start_supervised!(
        {Client,
         [
           bot_id: "bot-1",
           secret: "secret-1",
           dispatcher: Dispatcher.new(),
           ws_url: "ws://127.0.0.1:#{port}/",
           auto_reconnect: false,
           auth_timeout_ms: 50
         ]},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive {:client_frame, %{"cmd" => "aibot_subscribe"}}, 2_000
    assert Client.status(pid) == :authenticating
    assert {:error, %Error{reason: :not_connected}} = Bot.send_markdown(pid, "chat-1", 2, "early")
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :auth_timeout}}, 2_000
  end

  test "heartbeat timer resets missed pongs on ack and disconnects after three missed pongs" do
    {pid, server} = start_connected(Dispatcher.new(), heartbeat_interval_ms: 25)
    ref = Process.monitor(pid)

    assert_receive {:client_frame, %{"cmd" => "ping", "headers" => %{"req_id" => ping_1}}}, 2_000
    send(server, {:push, %{"headers" => %{"req_id" => ping_1}, "errcode" => 0}})

    for _ <- 1..3 do
      assert_receive {:client_frame, %{"cmd" => "ping"}}, 2_000
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :heartbeat_timeout}}, 2_000
  end

  test "proactive send uses a fresh req_id and surfaces non-zero ack errcodes" do
    {pid, server} = start_connected(Dispatcher.new())

    task = Task.async(fn -> Bot.send_markdown(pid, "chat-1", 2, "hello") end)

    assert_receive {:client_frame, %{"cmd" => "aibot_send_msg"} = frame}, 2_000
    req_id = frame["headers"]["req_id"]
    assert String.starts_with?(req_id, "aibot_send_msg_")

    assert frame["body"] == %{
             "chatid" => "chat-1",
             "chat_type" => 2,
             "msgtype" => "markdown",
             "markdown" => %{"content" => "hello"}
           }

    send(
      server,
      {:push, %{"headers" => %{"req_id" => req_id}, "errcode" => 45_009, "errmsg" => "freq"}}
    )

    assert {:error, %Error{reason: :rate_limited, code: 45_009}} = Task.await(task, 2_000)
  end

  test "media upload runs init, ordered chunks, and finish" do
    {pid, server} = start_connected(Dispatcher.new())

    content = :crypto.strong_rand_bytes(700 * 1024)
    task = Task.async(fn -> Bot.upload_media(pid, "file", "big.bin", content) end)

    assert_receive {:client_frame, %{"cmd" => "aibot_upload_media_init"} = init}, 2_000
    assert init["body"]["filename"] == "big.bin"
    assert init["body"]["total_size"] == byte_size(content)
    assert init["body"]["total_chunks"] == 2
    assert init["body"]["md5"] == Base.encode16(:crypto.hash(:md5, content), case: :lower)

    send(
      server,
      {:push,
       %{
         "headers" => %{"req_id" => init["headers"]["req_id"]},
         "errcode" => 0,
         "body" => %{"upload_id" => "up-1"}
       }}
    )

    for index <- 0..1 do
      assert_receive {:client_frame, %{"cmd" => "aibot_upload_media_chunk"} = chunk}, 5_000
      assert chunk["body"]["upload_id"] == "up-1"
      assert chunk["body"]["chunk_index"] == index

      send(
        server,
        {:push, %{"headers" => %{"req_id" => chunk["headers"]["req_id"]}, "errcode" => 0}}
      )
    end

    assert_receive {:client_frame, %{"cmd" => "aibot_upload_media_finish"} = finish}, 2_000
    assert finish["body"] == %{"upload_id" => "up-1"}

    send(
      server,
      {:push,
       %{
         "headers" => %{"req_id" => finish["headers"]["req_id"]},
         "errcode" => 0,
         "body" => %{"media_id" => "media-9"}
       }}
    )

    assert {:ok, "media-9"} = Task.await(task, 5_000)
  end

  test "stops as connection_contended on disconnected_event instead of reconnecting" do
    {pid, server} = start_connected(Dispatcher.new())
    ref = Process.monitor(pid)

    send(
      server,
      {:push,
       %{
         "cmd" => "aibot_event_callback",
         "headers" => %{"req_id" => "req-evt"},
         "body" => %{
           "msgtype" => "event",
           "event" => %{"eventtype" => "disconnected_event"}
         }
       }}
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :connection_contended}}, 2_000
  end

  test "stops as auth error when the subscribe ack is rejected" do
    parent = self()
    {server, port} = FakeWsServer.start(parent)
    on_exit(fn -> send(server, :close) end)

    pid =
      start_supervised!(
        {Client,
         [
           bot_id: "bot-1",
           secret: "wrong",
           dispatcher: Dispatcher.new(),
           ws_url: "ws://127.0.0.1:#{port}/",
           auto_reconnect: false
         ]},
        restart: :temporary
      )

    ref = Process.monitor(pid)

    assert_receive {:client_frame, %{"cmd" => "aibot_subscribe"} = auth}, 2_000

    send(
      server,
      {:push,
       %{
         "headers" => %{"req_id" => auth["headers"]["req_id"]},
         "errcode" => 301_058,
         "errmsg" => "invalid secret"
       }}
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, %Error{reason: :auth}}}, 2_000
  end

  test "upgrading times out without stalling indefinitely when upgrade headers never complete" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)
    test_pid = self()

    holder =
      spawn_link(fn ->
        {:ok, conn} = :gen_tcp.accept(listen)
        send(test_pid, :accepted)

        receive do
          :close -> :gen_tcp.close(conn)
        end
      end)

    on_exit(fn -> send(holder, :close) end)

    pid =
      start_supervised!(
        {Client,
         [
           bot_id: "bot-1",
           secret: "secret-1",
           dispatcher: Dispatcher.new(),
           ws_url: "ws://127.0.0.1:#{port}/",
           auto_reconnect: false,
           auth_timeout_ms: 40
         ]},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive :accepted, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :upgrade_timeout}}, 2_000
  end

  test "reconnects via :state_timeout, acks ping_-prefixed req_ids, avoids ghost queued sends, and handles calls after stop" do
    {pid, server} =
      start_connected(Dispatcher.new(),
        auto_reconnect: true,
        reconnect_base_ms: 15,
        ack_timeout_ms: 400
      )

    # A reply whose inbound req_id starts with "ping_" is still matched in data.pending.
    ping_reply = Task.async(fn -> Client.reply(pid, "ping_req_1", %{"text" => "ponged"}) end)
    assert_receive {:client_frame, %{"headers" => %{"req_id" => "ping_req_1"}}}, 2_000
    send(server, {:push, %{"headers" => %{"req_id" => "ping_req_1"}, "errcode" => 0}})
    assert {:ok, %{"errcode" => 0}} = Task.await(ping_reply, 2_000)

    # A second reply queued for the same req_id whose caller timeout expires must not ghost-send later.
    first = Task.async(fn -> Client.reply(pid, "same-req", %{"seq" => 1}) end)

    assert_receive {:client_frame,
                    %{"headers" => %{"req_id" => "same-req"}, "body" => %{"seq" => 1}}},
                   2_000

    second =
      Task.async(fn ->
        Client.reply(pid, "same-req", %{"seq" => 2}, timeout: 30)
      end)

    assert {:error, %Error{reason: :ack_timeout}} = Task.await(second, 2_000)
    send(server, {:push, %{"headers" => %{"req_id" => "same-req"}, "errcode" => 0}})
    assert {:ok, %{"errcode" => 0}} = Task.await(first, 2_000)
    refute_receive {:client_frame, %{"body" => %{"seq" => 2}}}, 80

    # Auto-reconnect resumes via :state_timeout after the socket drops, and stop/1 returns :not_connected cleanly.
    send(server, :close)

    wait_until(fn ->
      Client.status(pid) in [:disconnected, :upgrading, :authenticating, :connected]
    end)

    :ok = Client.stop(pid)
    assert {:error, %Error{reason: :not_connected}} = Client.request(pid, "aibot_send_msg", %{})
  end
end
