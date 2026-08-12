defmodule FakeFeishu.SimTest do
  use ExUnit.Case, async: false

  alias FakeFeishu.EventHub
  alias FakeFeishu.Sim
  alias FakeFeishu.State
  alias FeishuOpenAPI.WS.Frame

  setup do
    hub = start_supervised!({EventHub, name: EventHub})
    state = start_supervised!({State, owner: EventHub, cardkit_enabled: true})
    :ok = EventHub.attach_state(hub, state)
    :ok = State.register_app(state, "app_a", "s", bot_open_id: "ou_bot_a")
    :ok = Sim.seed_default_chats(state, "app_a", ["Alice", "Bob"])
    :ok = State.register_conn(state, self(), 1, "app_a")
    {:ok, state: state}
  end

  test "seeds the general group and one p2p chat per app", %{state: state} do
    assert [%{id: "oc_sim_general"} = general, %{id: "oc_sim_p2p_app_a", type: "p2p"}] =
             State.chats(state)

    member_names = Enum.map(general.members, & &1.name)
    assert "Alice" in member_names and "Bob" in member_names

    # Repeated seeding adds nothing.
    :ok = Sim.seed_default_chats(state, "app_a", ["Alice", "Bob"])
    assert length(State.chats(state)) == 2
  end

  test "sends a mention-bot message with the platform mention shape", %{state: state} do
    assert {:ok, %{"message_id" => message_id}} =
             Sim.send_user_message(state, "oc_sim_general", %{
               "text" => "ping",
               "mention_bot" => true
             })

    assert_receive {:push_frames, [frame_bin]}, 1_000
    {:ok, frame} = Frame.decode(frame_bin)
    envelope = JSON.decode!(frame.payload)
    message = envelope["event"]["message"]

    assert [mention] = message["mentions"]
    assert mention["key"] == "@_user_1"
    assert mention["id"]["open_id"] == "ou_bot_a"
    assert JSON.decode!(message["content"])["text"] == "@_user_1 ping"

    assert State.message(state, message_id).sender == :user
    assert [%{"type" => "user_message"} | _rest] = user_events()
  end

  test "reply threading resolves parent and root ids", %{state: state} do
    assert {:ok, %{"message_id" => first_id}} =
             Sim.send_user_message(state, "oc_sim_general", %{"text" => "first"})

    assert_receive {:push_frames, _first_frames}

    assert {:ok, %{"message_id" => _reply_id}} =
             Sim.send_user_message(state, "oc_sim_general", %{
               "text" => "second",
               "reply_to" => first_id
             })

    assert_receive {:push_frames, [frame_bin]}
    {:ok, frame} = Frame.decode(frame_bin)
    message = JSON.decode!(frame.payload)["event"]["message"]
    assert message["parent_id"] == first_id
    assert message["root_id"] == first_id
  end

  test "file sends seed the inbound resource the adapter downloads", %{state: state} do
    assert {:ok, %{"message_id" => message_id}} =
             Sim.send_user_message(state, "oc_sim_general", %{
               "file" => %{"name" => "note.txt", "base64" => Base.encode64("hello")}
             })

    assert_receive {:push_frames, [frame_bin]}
    {:ok, frame} = Frame.decode(frame_bin)
    message = JSON.decode!(frame.payload)["event"]["message"]
    assert message["message_type"] == "file"

    %{"file_key" => file_key} = JSON.decode!(message["content"])

    assert {:ok, %{content: "hello", name: "note.txt"}} =
             State.fetch_download(state, message_id, file_key)
  end

  test "transcript resolves card text and the hub reports card updates", %{state: state} do
    {:ok, %{"card_id" => card_id}} =
      State.cardkit_create_card(state, %{"data" => JSON.encode!(%{"body" => %{"elements" => []}})})

    {:ok, _message} =
      State.bot_post_message(state, %{
        "receive_id" => "oc_sim_general",
        "msg_type" => "interactive",
        "content" => JSON.encode!(%{type: "card", data: %{card_id: card_id}})
      })

    {:ok, %{}} =
      State.cardkit_element_content(state, card_id, "answer", %{
        "content" => "streamed",
        "sequence" => 1,
        "uuid" => "u1"
      })

    assert [%{"msg_type" => "interactive", "text" => "streamed"}] =
             Sim.transcript(state, "oc_sim_general")

    assert %{"type" => "card_updated", "text" => "streamed"} =
             Enum.find(all_events(), &(&1["type"] == "card_updated"))
  end

  defp user_events do
    Enum.filter(all_events(), &(&1["type"] == "user_message"))
  end

  defp all_events do
    # EventHub processing is asynchronous to the State call that caused it.
    Process.sleep(50)
    EventHub.events_since(EventHub, 0)
  end
end
