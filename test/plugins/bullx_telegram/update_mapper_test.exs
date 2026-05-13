defmodule BullxTelegram.UpdateMapperTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.{Source, UpdateMapper}

  defp source(overrides \\ %{}) do
    base = %Source{
      adapter: "telegram",
      channel_id: "main",
      bot_id: "100",
      bot_username: "bullx_bot",
      attention: %{
        "allowed_chat_ids" => [],
        "ignored_chat_ids" => [],
        "ignored_thread_ids" => [],
        "require_mention" => true,
        "free_response_chat_ids" => []
      },
      source_config: %BullX.Gateway.SourceConfig{
        adapter: "telegram",
        channel_id: "main"
      }
    }

    Map.merge(base, overrides)
  end

  test "private text message maps to Gateway message input with stringified ids" do
    update = %{
      "update_id" => 100,
      "message" => %{
        "message_id" => 42,
        "date" => 1_715_558_400,
        "from" => %{"id" => 999, "is_bot" => false, "first_name" => "Alice"},
        "chat" => %{"id" => 999, "type" => "private"},
        "text" => "hello"
      }
    }

    assert {:ok, %{input: input, account_input: account_input}} =
             UpdateMapper.map_update(update, source())

    assert input["adapter"] == "telegram"
    assert input["channel_id"] == "main"
    assert input["scope_id"] == "999"
    assert input["thread_id"] == nil
    assert input["occurrence_key"] == "telegram:main:update:100"
    assert input["actor"]["id"] == "telegram:999"
    assert input["actor"]["display"] == "Alice"
    assert input["event"]["type"] == "message"
    assert input["event"]["data"]["update_id"] == "100"
    assert input["event"]["data"]["message_id"] == "42"
    assert input["event"]["data"]["chat_id"] == "999"
    assert input["event"]["data"]["attention_reason"] == "dm"
    assert [%{"kind" => "text", "body" => %{"text" => "hello"}}] = input["content"]

    assert account_input["adapter"] == "telegram"
    assert account_input["external_id"] == "telegram:999"
    assert account_input["channel_id"] == "main"
  end

  test "/ping in private chat returns :direct_command" do
    update = %{
      "update_id" => 101,
      "message" => %{
        "message_id" => 43,
        "date" => 1_715_558_400,
        "from" => %{"id" => 999, "is_bot" => false},
        "chat" => %{"id" => 999, "type" => "private"},
        "text" => "/ping"
      }
    }

    assert {:direct_command, command} = UpdateMapper.map_update(update, source())
    assert command.name == "ping"
    assert command.chat_type == "private"
    assert command.chat_id == "999"
  end

  test "unmentioned group message is ignored" do
    update = %{
      "update_id" => 102,
      "message" => %{
        "message_id" => 44,
        "from" => %{"id" => 999, "is_bot" => false},
        "chat" => %{"id" => -100, "type" => "supergroup"},
        "text" => "chit chat"
      }
    }

    assert {:ignore, :unmentioned_group_message} = UpdateMapper.map_update(update, source())
  end

  test "self-sent bot message is filtered" do
    update = %{
      "update_id" => 103,
      "message" => %{
        "message_id" => 45,
        "from" => %{"id" => 100, "is_bot" => true},
        "chat" => %{"id" => -100, "type" => "supergroup"},
        "text" => "I am the bot"
      }
    }

    assert {:ignore, :bot_author} = UpdateMapper.map_update(update, source())
  end

  test "supergroup with forum thread maps thread_id" do
    update = %{
      "update_id" => 104,
      "message" => %{
        "message_id" => 46,
        "message_thread_id" => 7,
        "from" => %{"id" => 999, "is_bot" => false},
        "chat" => %{"id" => -100, "type" => "supergroup"},
        "text" => "hey @bullx_bot"
      }
    }

    assert {:ok, %{input: input}} = UpdateMapper.map_update(update, source())
    assert input["thread_id"] == "7"
    assert input["event"]["data"]["thread_id"] == "7"
    assert input["event"]["data"]["attention_reason"] == "mention"
  end

  test "non-/ping slash command in private maps to slash_command type" do
    update = %{
      "update_id" => 105,
      "message" => %{
        "message_id" => 47,
        "from" => %{"id" => 999, "is_bot" => false},
        "chat" => %{"id" => 999, "type" => "private"},
        "text" => "/help me out"
      }
    }

    assert {:ok, %{input: input}} = UpdateMapper.map_update(update, source())
    assert input["event"]["type"] == "slash_command"
    assert input["event"]["data"]["command_name"] == "help"
    assert input["event"]["data"]["args"] == "me out"
  end

  test "non-message update yields ignore" do
    update = %{"update_id" => 200, "callback_query" => %{"id" => "cb"}}

    assert {:ignore, :unsupported_update} = UpdateMapper.map_update(update, source())
  end
end
