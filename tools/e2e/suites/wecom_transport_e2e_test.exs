defmodule Ankole.E2E.WeComTransportTest do
  use ExUnit.Case, async: false

  alias Ankole.E2E.FakeWeCom.{Server, State}
  alias WeComOpenAPI.Bot
  alias WeComOpenAPI.Bot.Client, as: BotClient
  alias WeComOpenAPI.Bot.Dispatcher
  alias WeComOpenAPI.Error

  defp connect(fake, dispatcher, opts \\ []) do
    socket =
      start_supervised!(
        {BotClient,
         [
           bot_id: "bot_fake",
           secret: "secret_fake",
           dispatcher: dispatcher,
           ws_url: fake.ws_url
         ] ++ opts}
      )

    wait_until(fn ->
      BotClient.status(socket) == :connected and State.connection_count(fake.state) == 1
    end)

    socket
  end

  test "authenticates in-band, dispatches message callbacks, and serializes replies per req_id" do
    fake = Server.start!(auto_ack: false)
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_message(fn event ->
        send(parent, {:message, event.msgid, event.req_id})
        :ok
      end)

    socket = connect(fake, dispatcher)

    # The subscribe frame carried the credentials.
    assert [auth] = State.frames(fake.state, "aibot_subscribe")
    assert auth["body"] == %{"bot_id" => "bot_fake", "secret" => "secret_fake"}

    # A message callback reaches the dispatcher with its reply anchor.
    :ok =
      State.push_message(fake.state, "req-in-1", %{
        "msgid" => "m-1",
        "chattype" => "single",
        "from" => %{"userid" => "alice"},
        "msgtype" => "text",
        "text" => %{"content" => "hi"}
      })

    assert_receive {:message, "m-1", "req-in-1"}, 2_000

    # Two replies to one req_id: the second frame goes out only after the first
    # ack (acks are attributable only by req_id).
    task_one = Task.async(fn -> Bot.reply_markdown(socket, "req-in-1", "first") end)

    wait_until(fn -> length(State.frames(fake.state, "aibot_respond_msg")) == 1 end)
    task_two = Task.async(fn -> Bot.reply_markdown(socket, "req-in-1", "second") end)

    Process.sleep(150)
    assert length(State.frames(fake.state, "aibot_respond_msg")) == 1

    :ok = State.push_ack(fake.state, "req-in-1")
    assert {:ok, _ack} = Task.await(task_one, 2_000)

    wait_until(fn -> length(State.frames(fake.state, "aibot_respond_msg")) == 2 end)
    [first, second] = State.frames(fake.state, "aibot_respond_msg")
    assert first["body"]["markdown"]["content"] == "first"
    assert second["body"]["markdown"]["content"] == "second"

    :ok = State.push_ack(fake.state, "req-in-1")
    assert {:ok, _ack} = Task.await(task_two, 2_000)
  end

  test "a rejected subscribe stops the client as a fatal auth error" do
    fake = Server.start!(auth_errcode: 301_058)

    {:ok, socket} =
      BotClient.start_link(
        bot_id: "bot_fake",
        secret: "wrong",
        dispatcher: Dispatcher.new(),
        ws_url: fake.ws_url
      )

    Process.unlink(socket)
    ref = Process.monitor(socket)

    assert_receive {:DOWN, ^ref, :process, ^socket, {:shutdown, %Error{reason: :auth}}}, 3_000
  end

  test "a disconnected_event kick stops the client without a reconnect fight" do
    fake = Server.start!()

    # Unsupervised on purpose: a supervisor restart after the deliberate stop
    # would look like the kick fight this test proves cannot happen.
    {:ok, socket} =
      BotClient.start_link(
        bot_id: "bot_fake",
        secret: "secret_fake",
        dispatcher: Dispatcher.new(),
        ws_url: fake.ws_url
      )

    wait_until(fn ->
      BotClient.status(socket) == :connected and State.connection_count(fake.state) == 1
    end)

    Process.unlink(socket)
    ref = Process.monitor(socket)

    :ok = State.push_event(fake.state, "req-kick", "disconnected_event")

    assert_receive {:DOWN, ^ref, :process, ^socket, {:shutdown, :connection_contended}}, 3_000

    # No new connection appears: reconnecting would kick the new holder back.
    Process.sleep(300)
    assert State.connection_generation(fake.state) == 1
  end

  test "a dropped socket reconnects with a fresh in-band auth" do
    fake = Server.start!()
    socket = connect(fake, Dispatcher.new())
    generation = State.connection_generation(fake.state)

    :ok = State.close_conns(fake.state)

    wait_until(fn ->
      State.connection_generation(fake.state) > generation and
        State.connection_count(fake.state) == 1 and
        BotClient.status(socket) == :connected
    end)

    assert length(State.frames(fake.state, "aibot_subscribe")) == 2
  end

  defp wait_until(fun, attempts \\ 150)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met before timeout")
end
