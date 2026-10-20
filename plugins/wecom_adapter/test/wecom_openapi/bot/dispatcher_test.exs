defmodule WeComOpenAPI.Bot.DispatcherTest do
  use ExUnit.Case, async: true

  alias WeComOpenAPI.Bot.{Dispatcher, Event}

  defp message_event do
    Event.from_frame(%{
      "cmd" => "aibot_msg_callback",
      "headers" => %{"req_id" => "req-1"},
      "body" => %{"msgid" => "m-1", "msgtype" => "text", "text" => %{"content" => "hi"}}
    })
  end

  defp event_event(eventtype) do
    Event.from_frame(%{
      "cmd" => "aibot_event_callback",
      "headers" => %{"req_id" => "req-2"},
      "body" => %{"msgtype" => "event", "event" => %{"eventtype" => eventtype}}
    })
  end

  test "routes message callbacks to the message handler" do
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_message(fn event ->
        send(parent, {:message, event.msgid, event.req_id, event.msgtype})
        :ok
      end)

    assert Dispatcher.dispatch(dispatcher, message_event()) == :ok
    assert_received {:message, "m-1", "req-1", "text"}
  end

  test "routes event callbacks by eventtype and ignores unregistered types" do
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_event("template_card_event", fn event ->
        send(parent, {:event, event.event_type})
        :ok
      end)

    assert Dispatcher.dispatch(dispatcher, event_event("template_card_event")) == :ok
    assert_received {:event, "template_card_event"}

    assert Dispatcher.dispatch(dispatcher, event_event("feedback_event")) == :ignored
  end

  test "without a message handler messages are ignored" do
    assert Dispatcher.dispatch(Dispatcher.new(), message_event()) == :ignored
  end

  test "handler errors and crashes surface as {:error, _}" do
    erroring = Dispatcher.new() |> Dispatcher.on_message(fn _event -> {:error, :nope} end)
    assert {:error, :nope} = Dispatcher.dispatch(erroring, message_event())

    crashing = Dispatcher.new() |> Dispatcher.on_message(fn _event -> raise "boom" end)

    assert {:error, {:handler_exception, %RuntimeError{}, _stack}} =
             Dispatcher.dispatch(crashing, message_event())
  end
end
