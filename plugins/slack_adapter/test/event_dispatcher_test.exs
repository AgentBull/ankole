defmodule SlackOpenAPI.EventDispatcherTest do
  use ExUnit.Case, async: true

  alias SlackOpenAPI.Event
  alias SlackOpenAPI.SocketMode.{Client, Dispatcher}

  test "events_api envelope normalizes and dispatches" do
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on("message", fn type, event ->
        send(parent, {:event, type, event})
        :handled
      end)

    envelope = %{
      "envelope_id" => "env-1",
      "retry_attempt" => 1,
      "type" => "events_api",
      "payload" => %{
        "event_id" => "Ev1",
        "event_time" => 1_700_000_000,
        "team_id" => "T1",
        "api_app_id" => "A1",
        "event" => %{"type" => "message", "text" => "hello"}
      }
    }

    assert {:ok, :handled} = Dispatcher.dispatch(dispatcher, {:envelope, envelope})
    assert_receive {:event, "message", %Event{id: "Ev1", retry_attempt: 1, team_id: "T1"}}
  end

  test "interactive envelope uses payload type and envelope id" do
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_interactive("block_actions", fn _, event ->
        send(parent, event)
        :ok
      end)

    envelope = %{
      "envelope_id" => "env-action",
      "type" => "interactive",
      "payload" => %{"type" => "block_actions", "user" => %{"id" => "U1"}}
    }

    assert {:ok, :ok} = Dispatcher.dispatch(dispatcher, {:envelope, envelope})
    assert_receive %Event{id: "env-action", type: "block_actions"}
  end

  test "ack encoder emits the exact Slack envelope" do
    assert Torque.decode!(Client.encode_ack("env-1")) == %{"envelope_id" => "env-1"}
  end
end
