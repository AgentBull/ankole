defmodule Ankole.E2E.SlackTransportTest do
  use ExUnit.Case, async: false

  alias Ankole.E2E.FakeSlack.{Server, State}
  alias SlackOpenAPI.SocketMode.{Client, Dispatcher}

  test "Socket Mode dispatches, acknowledges, and survives refresh_requested" do
    fake = Server.start!()
    parent = self()

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on("message", fn _type, event ->
        send(parent, {:message, event.id, event.content["text"]})
        {:ok, :persisted}
      end)

    client =
      SlackOpenAPI.Client.new(
        bot_token: "xoxb-fake",
        app_token: "xapp-fake",
        base_url: fake.base_url
      )

    socket = start_supervised!({Client, client: client, dispatcher: dispatcher})

    wait_until(fn ->
      Client.status(socket) == :connected and State.connection_count(fake.state) == 1
    end)

    assert :ok = State.push_event(fake.state, envelope("env-1", "Ev1", "first"))
    assert_receive {:message, "Ev1", "first"}, 2_000
    wait_until(fn -> State.acked?(fake.state, "env-1") end)

    assert :ok = State.push_disconnect(fake.state, "refresh_requested")

    wait_until(fn ->
      Client.status(socket) == :connected and State.connection_generation(fake.state) >= 2
    end)

    assert :ok = State.push_event(fake.state, envelope("env-2", "Ev2", "after refresh"))
    assert_receive {:message, "Ev2", "after refresh"}, 2_000
    wait_until(fn -> State.acked?(fake.state, "env-2") end)
  end

  defp envelope(envelope_id, event_id, text) do
    %{
      "envelope_id" => envelope_id,
      "type" => "events_api",
      "accepts_response_payload" => false,
      "payload" => %{
        "event_id" => event_id,
        "event_time" => 1_700_000_000,
        "team_id" => "TFAKE",
        "api_app_id" => "AFAKE",
        "event" => %{
          "type" => "message",
          "channel" => "D1",
          "channel_type" => "im",
          "user" => "U1",
          "text" => text,
          "ts" => "1700000000.000100"
        }
      }
    }
  end

  defp wait_until(fun, attempts \\ 250)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_until(fun, attempts - 1)
        )
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met")
end
