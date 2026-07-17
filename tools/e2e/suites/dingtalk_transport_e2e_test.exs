defmodule Ankole.E2E.DingTalkTransportTest do
  use ExUnit.Case, async: false

  alias Ankole.E2E.FakeDingTalk.{Server, State}
  alias DingTalkOpenAPI.Stream.Client, as: StreamClient
  alias DingTalkOpenAPI.Stream.Dispatcher

  @message_topic "/v1.0/im/bot/messages/get"

  defp connect(fake, dispatcher) do
    client =
      DingTalkOpenAPI.Client.new(
        client_id: "cli_fake",
        client_secret: "secret_fake",
        api_base_url: fake.base_url,
        oapi_base_url: fake.base_url
      )

    socket = start_supervised!({StreamClient, client: client, dispatcher: dispatcher})

    wait_until(fn ->
      StreamClient.status(socket) == :connected and State.connection_count(fake.state) == 1
    end)

    socket
  end

  test "registers, connects, echoes a SYSTEM ping, and acks a CALLBACK after dispatch" do
    fake = Server.start!()
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback(@message_topic, fn _topic, event ->
        send(parent, {:callback, event.data})
        {:ok, %{"received" => true}}
      end)
      |> Dispatcher.on_event("user_add_org", fn _type, event ->
        send(parent, {:event, event.data})
        :ok
      end)

    connect(fake, dispatcher)

    # Registration carried the client id and derived subscriptions.
    assert [register_body | _] = State.register_bodies(fake.state)
    assert register_body["clientId"] == "cli_fake"
    assert %{"type" => "CALLBACK", "topic" => @message_topic} in register_body["subscriptions"]

    # SYSTEM ping is echoed with the same messageId and opaque.
    :ok = State.push_ping(fake.state, "ping-1", "op-1")
    wait_until(fn -> State.acked?(fake.state, "ping-1") end)
    ping_reply = State.ack_response(fake.state, "ping-1")
    assert ping_reply["code"] == 200
    assert Torque.decode!(ping_reply["data"]) == %{"opaque" => "op-1"}

    # CALLBACK is dispatched, then acked 200 with the handler response.
    :ok = State.push_callback(fake.state, "cb-1", @message_topic, %{"msgId" => "in-1"})
    assert_receive {:callback, %{"msgId" => "in-1"}}, 2_000
    wait_until(fn -> State.acked?(fake.state, "cb-1") end)
    cb_reply = State.ack_response(fake.state, "cb-1")
    assert cb_reply["code"] == 200
    assert Torque.decode!(cb_reply["data"]) == %{"response" => %{"received" => true}}

    # EVENT is dispatched, then acked SUCCESS.
    :ok = State.push_event(fake.state, "ev-1", "user_add_org", %{"userId" => ["u1"]})
    assert_receive {:event, %{"userId" => ["u1"]}}, 2_000
    wait_until(fn -> State.acked?(fake.state, "ev-1") end)

    assert Torque.decode!(State.ack_response(fake.state, "ev-1")["data"]) == %{
             "status" => "SUCCESS"
           }
  end

  test "a SYSTEM disconnect triggers re-registration and a fresh connection" do
    fake = Server.start!()
    parent = self()

    dispatcher =
      Dispatcher.on_event(Dispatcher.new(), "user_add_org", fn _type, event ->
        send(parent, {:event, event.data})
        :ok
      end)

    connect(fake, dispatcher)
    generation = State.connection_generation(fake.state)

    :ok = State.push_disconnect(fake.state)

    wait_until(fn ->
      State.connection_generation(fake.state) > generation and
        State.connection_count(fake.state) == 1
    end)

    # The re-registered connection still delivers events.
    :ok = State.push_event(fake.state, "ev-2", "user_add_org", %{"userId" => ["u2"]})
    assert_receive {:event, %{"userId" => ["u2"]}}, 2_000
  end

  test "an EVENT handler error acks LATER so the platform redelivers" do
    fake = Server.start!()

    dispatcher =
      Dispatcher.on_event(Dispatcher.new(), "user_add_org", fn _type, _event ->
        {:error, :simulated_ingress_failure}
      end)

    connect(fake, dispatcher)

    :ok = State.push_event(fake.state, "ev-late", "user_add_org", %{"userId" => ["u3"]})
    wait_until(fn -> State.acked?(fake.state, "ev-late") end)

    assert Torque.decode!(State.ack_response(fake.state, "ev-late")["data"]) == %{
             "status" => "LATER"
           }
  end

  defp wait_until(fun, attempts \\ 100)

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
