defmodule DingTalkOpenAPI.Stream.DispatcherTest do
  use ExUnit.Case, async: true

  alias DingTalkOpenAPI.Event
  alias DingTalkOpenAPI.Stream.Dispatcher

  defp callback_event(topic, data \\ %{}) do
    %Event{
      type: "CALLBACK",
      topic: topic,
      message_id: "m1",
      headers: %{"topic" => topic},
      data: data
    }
  end

  defp event(event_type, data \\ %{}) do
    %Event{
      type: "EVENT",
      event_type: event_type,
      headers: %{"eventType" => event_type},
      data: data
    }
  end

  test "callback success acks 200 with the handler response wrapped in response" do
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback("/v1.0/im/bot/messages/get", fn topic, event ->
        send(parent, {:handled, topic, event.data})
        {:ok, %{"ok" => true}}
      end)

    assert {:reply, 200, %{"response" => %{"ok" => true}}} =
             Dispatcher.dispatch(
               dispatcher,
               callback_event("/v1.0/im/bot/messages/get", %{"a" => 1})
             )

    assert_receive {:handled, "/v1.0/im/bot/messages/get", %{"a" => 1}}
  end

  test "callback with no registered topic acks 404" do
    assert {:reply, 404, %{}} =
             Dispatcher.dispatch(Dispatcher.new(), callback_event("/v1.0/unknown"))
  end

  test "callback handler error withholds the ack for redelivery" do
    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback("/v1.0/im/bot/messages/get", fn _t, _e -> {:error, :db_down} end)

    assert {:withhold, :db_down} =
             Dispatcher.dispatch(dispatcher, callback_event("/v1.0/im/bot/messages/get"))
  end

  test "callback handler crash is contained and withholds the ack" do
    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback("/v1.0/im/bot/messages/get", fn _t, _e -> raise "boom" end)

    assert {:withhold, {:handler_exception, %RuntimeError{}, _stack}} =
             Dispatcher.dispatch(dispatcher, callback_event("/v1.0/im/bot/messages/get"))
  end

  test "event handler success acks SUCCESS" do
    dispatcher = Dispatcher.new() |> Dispatcher.on_event("user_add_org", fn _t, _e -> :ok end)

    assert {:reply, 200, %{"status" => "SUCCESS"}} =
             Dispatcher.dispatch(dispatcher, event("user_add_org"))
  end

  test "event handler error acks LATER for redelivery" do
    dispatcher =
      Dispatcher.new() |> Dispatcher.on_event("user_add_org", fn _t, _e -> {:error, :later} end)

    assert {:reply, 200, %{"status" => "LATER"}} =
             Dispatcher.dispatch(dispatcher, event("user_add_org"))
  end

  test "unregistered event acks SUCCESS and is dropped" do
    assert {:reply, 200, %{"status" => "SUCCESS"}} =
             Dispatcher.dispatch(Dispatcher.new(), event("chat_add_member"))
  end

  test "subscription introspection lists callback topics and event presence" do
    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback("/v1.0/im/bot/messages/get", fn _, _ -> {:ok, %{}} end)
      |> Dispatcher.on_event("user_add_org", fn _, _ -> :ok end)

    assert Dispatcher.callback_topics(dispatcher) == ["/v1.0/im/bot/messages/get"]
    assert Dispatcher.events?(dispatcher)
    refute Dispatcher.events?(Dispatcher.new())
  end
end
