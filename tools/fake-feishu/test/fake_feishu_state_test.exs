defmodule FakeFeishu.StateTest do
  use ExUnit.Case, async: true

  alias FakeFeishu.State
  alias FeishuOpenAPI.WS.Frame

  defp start_state!(opts \\ []) do
    start_supervised!(
      {State, Keyword.put_new(opts, :owner, self())},
      id: System.unique_integer([:positive])
    )
  end

  defp decode_pushed_envelope! do
    assert_receive {:push_frames, [frame_bin]}, 1_000
    assert {:ok, frame} = Frame.decode(frame_bin)
    JSON.decode!(frame.payload)
  end

  describe "CardKit emulation" do
    test "disabled mode answers card creation with the fallback code 200860" do
      state = start_state!()

      assert {:error, 200_860, _msg} = State.cardkit_create_card(state, %{"data" => "{}"})
    end

    test "streams element content under sequence and uuid guards" do
      state = start_state!(cardkit_enabled: true)

      card_json =
        JSON.encode!(%{
          "schema" => "2.0",
          "body" => %{
            "elements" => [%{"tag" => "markdown", "element_id" => "answer", "content" => ""}]
          }
        })

      assert {:ok, %{"card_id" => card_id}} =
               State.cardkit_create_card(state, %{"type" => "card_json", "data" => card_json})

      assert {:error, 200_740, _msg} =
               State.cardkit_element_content(state, "crd_missing", "answer", %{
                 "content" => "x",
                 "sequence" => 1,
                 "uuid" => "u0"
               })

      assert {:ok, %{}} =
               State.cardkit_element_content(state, card_id, "answer", %{
                 "content" => "Hel",
                 "sequence" => 1,
                 "uuid" => "u1"
               })

      assert {:error, 200_770, _msg} =
               State.cardkit_element_content(state, card_id, "answer", %{
                 "content" => "Hello",
                 "sequence" => 2,
                 "uuid" => "u1"
               })

      assert {:error, 300_317, _msg} =
               State.cardkit_element_content(state, card_id, "answer", %{
                 "content" => "Hello",
                 "sequence" => 1,
                 "uuid" => "u2"
               })

      assert {:ok, %{}} =
               State.cardkit_element_content(state, card_id, "answer", %{
                 "content" => "Hello world",
                 "sequence" => 2,
                 "uuid" => "u3"
               })

      assert {:ok, %{"message_id" => message_id}} =
               State.bot_post_message(state, %{
                 "receive_id" => "oc_x",
                 "msg_type" => "interactive",
                 "content" => JSON.encode!(%{type: "card", data: %{card_id: card_id}})
               })

      assert State.rendered_message_text(state, message_id) == "Hello world"

      assert {:ok, %{}} =
               State.cardkit_batch_update(state, card_id, %{
                 "actions" =>
                   JSON.encode!([
                     %{
                       "action" => "partial_update_setting",
                       "params" => %{"settings" => %{"config" => %{"streaming_mode" => false}}}
                     }
                   ]),
                 "sequence" => 3,
                 "uuid" => "u4"
               })

      card = State.card(state, card_id)
      assert card.message_id == message_id
      assert get_in(card.settings, ["config", "streaming_mode"]) == false
    end
  end

  describe "chat registry and event routing" do
    test "routes a message to the apps whose bots are chat members" do
      state = start_state!()
      :ok = State.register_app(state, "app_a", "s", bot_open_id: "ou_bot_a")
      :ok = State.register_app(state, "app_b", "s", bot_open_id: "ou_bot_b")

      {:ok, _chat} =
        State.put_chat(state, %{
          "id" => "oc_only_b",
          "name" => "B room",
          "members" => [
            %{"type" => "user", "name" => "Alice"},
            %{"type" => "bot", "app_id" => "app_b"}
          ]
        })

      # The test process plays app_b's connection; app_a's connection is a
      # separate process so a mis-routed frame cannot reach this mailbox.
      other = spawn_link(fn -> Process.sleep(:infinity) end)
      :ok = State.register_conn(state, other, 1, "app_a")
      :ok = State.register_conn(state, self(), 2, "app_b")

      assert :ok =
               State.user_sends_message(state,
                 message_id: "om_1",
                 event_id: "evt_1",
                 chat_id: "oc_only_b",
                 text: "hi"
               )

      envelope = decode_pushed_envelope!()
      assert envelope["header"]["event_type"] == "im.message.receive_v1"
      assert envelope["header"]["app_id"] == "app_b"
      assert get_in(envelope, ["event", "message", "chat_id"]) == "oc_only_b"
      refute_receive {:push_frames, _frames}, 100
    end

    test "an unregistered chat id keeps the default-app routing" do
      state = start_state!()
      :ok = State.register_app(state, "app_a", "s")
      :ok = State.register_conn(state, self(), 1, "app_a")

      assert :ok =
               State.user_sends_message(state,
                 message_id: "om_2",
                 event_id: "evt_2",
                 chat_id: "oc_unregistered",
                 text: "hi"
               )

      assert %{"header" => %{"app_id" => "app_a"}} = decode_pushed_envelope!()
    end

    test "paginates chat members with page tokens" do
      state = start_state!()
      :ok = State.register_app(state, "app_a", "s", bot_open_id: "ou_bot_a")

      {:ok, _chat} =
        State.put_chat(state, %{
          "id" => "oc_page",
          "members" => [
            %{"type" => "user", "name" => "Alice"},
            %{"type" => "user", "name" => "Bob"},
            %{"type" => "bot", "app_id" => "app_a"}
          ]
        })

      assert {:ok, page_one} =
               State.list_chat_members(state, "oc_page", %{"page_size" => "2"})

      assert [%{"name" => "Alice"}, %{"name" => "Bob"}] = page_one["items"]
      assert page_one["has_more"] == true

      assert {:ok, page_two} =
               State.list_chat_members(state, "oc_page", %{
                 "page_size" => "2",
                 "page_token" => page_one["page_token"]
               })

      assert [%{"member_type" => "bot", "open_id" => "ou_bot_a"}] = page_two["items"]
      assert page_two["has_more"] == false
    end

    test "lists only the chats whose members include the asking app's bot" do
      state = start_state!()
      :ok = State.register_app(state, "app_a", "s", bot_open_id: "ou_bot_a")
      :ok = State.register_app(state, "app_b", "s", bot_open_id: "ou_bot_b")

      {:ok, _chat} =
        State.put_chat(state, %{
          "id" => "oc_a",
          "members" => [%{"type" => "bot", "app_id" => "app_a"}]
        })

      {:ok, _chat} =
        State.put_chat(state, %{
          "id" => "oc_b",
          "members" => [%{"type" => "bot", "app_id" => "app_b"}]
        })

      assert {:ok, %{"items" => [%{"chat_id" => "oc_a"}]}} =
               State.list_chats(state, "app_a", %{})
    end

    test "member changes push the matching membership events" do
      state = start_state!()
      :ok = State.register_app(state, "app_a", "s", bot_open_id: "ou_bot_a")

      {:ok, _chat} =
        State.put_chat(state, %{
          "id" => "oc_members",
          "members" => [%{"type" => "bot", "app_id" => "app_a"}]
        })

      :ok = State.register_conn(state, self(), 1, "app_a")

      {:ok, _member} =
        State.add_chat_member(state, "oc_members", %{"type" => "user", "name" => "Carol"})

      envelope = decode_pushed_envelope!()
      assert envelope["header"]["event_type"] == "im.chat.member.user.added_v1"
      assert get_in(envelope, ["event", "chat_id"]) == "oc_members"
      assert get_in(envelope, ["event", "user_id"]) == "carol"

      :ok = State.remove_chat_member(state, "oc_members", "Carol")
      envelope = decode_pushed_envelope!()
      assert envelope["header"]["event_type"] == "im.chat.member.user.deleted_v1"
    end
  end

  describe "reactions and card actions" do
    setup do
      state = start_state!(cardkit_enabled: true)
      :ok = State.register_app(state, "app_a", "s")
      :ok = State.register_conn(state, self(), 1, "app_a")

      assert :ok =
               State.user_sends_message(state,
                 message_id: "om_seed",
                 event_id: "evt_seed",
                 chat_id: "oc_chaos_group",
                 text: "seed"
               )

      _seed_envelope = decode_pushed_envelope!()
      {:ok, state: state}
    end

    test "a user reaction updates the message and pushes the event", %{state: state} do
      assert :ok =
               State.user_adds_reaction(state,
                 message_id: "om_seed",
                 emoji_type: "THUMBSUP",
                 operator_open_id: "ou_open_alice"
               )

      envelope = decode_pushed_envelope!()
      assert envelope["header"]["event_type"] == "im.message.reaction.created_v1"
      assert get_in(envelope, ["event", "reaction_type", "emoji_type"]) == "THUMBSUP"
      assert get_in(envelope, ["event", "chat_id"]) == "oc_chaos_group"

      assert [%{key: "THUMBSUP"}] = State.message(state, "om_seed").reactions

      assert :ok =
               State.user_removes_reaction(state,
                 message_id: "om_seed",
                 emoji_type: "THUMBSUP",
                 operator_open_id: "ou_open_alice"
               )

      envelope = decode_pushed_envelope!()
      assert envelope["header"]["event_type"] == "im.message.reaction.deleted_v1"
      assert State.message(state, "om_seed").reactions == []
    end

    test "a card action pushes a card-typed frame with the callback shape", %{state: state} do
      assert :ok =
               State.trigger_card_action(state,
                 message_id: "om_seed",
                 value: %{"action" => "confirm"},
                 operator_open_id: "ou_open_alice"
               )

      assert_receive {:push_frames, [frame_bin]}, 1_000
      assert {:ok, frame} = Frame.decode(frame_bin)
      assert Frame.type(frame) == "card"

      envelope = JSON.decode!(frame.payload)
      assert envelope["header"]["event_type"] == "card.action.trigger"
      assert get_in(envelope, ["event", "action", "value"]) == %{"action" => "confirm"}
      assert get_in(envelope, ["event", "context", "open_message_id"]) == "om_seed"
    end
  end

  describe "app registration" do
    test "auto-registers unknown apps only when enabled" do
      strict = start_state!()
      assert :error = State.authenticate_app(strict, "cli_new", "secret")

      relaxed = start_state!(auto_register_apps: true)
      assert :ok = State.authenticate_app(relaxed, "cli_new", "secret")
      assert :ok = State.authenticate_app(relaxed, "cli_new", "secret")
      assert :error = State.authenticate_app(relaxed, "cli_new", "wrong")
      assert State.bot_open_id(relaxed, "cli_new") == "ou_bot_cli_new"
      assert_receive {:fake_feishu, {:app_auto_registered, "cli_new"}}
    end
  end
end
