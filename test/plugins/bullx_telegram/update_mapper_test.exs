defmodule BullxTelegram.UpdateMapperTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.{ContentMapper, Source, UpdateMapper}

  defp default_attention do
    %{
      "allowed_chat_ids" => [],
      "ignored_chat_ids" => [],
      "ignored_thread_ids" => [],
      "require_mention" => true,
      "free_response_chat_ids" => []
    }
  end

  test "maps a private Telegram text update into CloudEvent attrs" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 18293,
      "message" => %{
        "message_id" => 421,
        "date" => 1_779_000_000,
        "chat" => %{"id" => 987_654_321, "type" => "private"},
        "from" => %{"id" => 987_654_321, "first_name" => "Alice", "is_bot" => false},
        "text" => "hello"
      }
    }

    assert {:ok, %{attrs: attrs, account_input: account_input}} = UpdateMapper.map(update, source)

    assert attrs.type == "bullx.message.received"
    assert attrs.source == "telegram://main/bot/123456"
    assert get_in(attrs.data, [:channel, :adapter]) == "telegram"
    assert get_in(attrs.data, [:channel, :kind]) == "dm"
    assert get_in(attrs.data, [:scope, :id]) == "987654321"
    assert get_in(attrs.data, [:actor, :external_account_id]) == "telegram:987654321"
    assert get_in(attrs.data, [:actor, :display_name]) == "Alice"
    assert get_in(attrs.data, [:actor, :principal]) == nil
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "dm"
    assert get_in(attrs.data, [:routing_facts, "group_message_mode"]) == "addressed_only"
    assert account_input["external_id"] == "telegram:987654321"
  end

  test "engage_all emits unmentioned group messages as ambient" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention(),
      group_message_mode: :engage_all
    }

    update = %{
      "update_id" => 100,
      "message" => %{
        "message_id" => 200,
        "chat" => %{"id" => 555, "type" => "group"},
        "from" => %{"id" => 600, "first_name" => "Bob", "is_bot" => false},
        "text" => "casual chatter"
      }
    }

    assert {:ok, %{attrs: attrs}} = UpdateMapper.map(update, source)
    assert attrs.type == "bullx.message.received"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "unaddressed"
    assert get_in(attrs.data, [:routing_facts, "group_message_mode"]) == "engage_all"
  end

  test "addressed_only ignores unmentioned group messages" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 101,
      "message" => %{
        "message_id" => 201,
        "chat" => %{"id" => 555, "type" => "group"},
        "from" => %{"id" => 600, "first_name" => "Bob", "is_bot" => false},
        "text" => "casual chatter"
      }
    }

    assert {:ignore, :unmentioned_group_message} = UpdateMapper.map(update, source)
  end

  test "group message with bot mention entity is addressed" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 102,
      "message" => %{
        "message_id" => 202,
        "chat" => %{"id" => 555, "type" => "group"},
        "from" => %{"id" => 600, "first_name" => "Bob", "is_bot" => false},
        "text" => "hello @bullx_bot",
        "entities" => [%{"type" => "mention", "offset" => 6, "length" => 10}]
      }
    }

    assert {:ok, %{attrs: attrs}} = UpdateMapper.map(update, source)
    assert attrs.type == "bullx.message.received"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "mention"
  end

  test "telegram mention detection does not match username substrings" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 103,
      "message" => %{
        "message_id" => 203,
        "chat" => %{"id" => 555, "type" => "group"},
        "from" => %{"id" => 600, "first_name" => "Bob", "is_bot" => false},
        "text" => "hello @bullx_botany"
      }
    }

    assert {:ignore, :unmentioned_group_message} = UpdateMapper.map(update, source)
  end

  test "normalizes localized command aliases to command events" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 2,
        "chat" => %{"id" => 3, "type" => "private"},
        "from" => %{"id" => 4, "is_bot" => false},
        "text" => "/新会话"
      }
    }

    assert {:ok, %{attrs: attrs}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> UpdateMapper.map(update, source) end)

    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "new"
    assert attrs.data.command.name == "new"
  end

  test "maps status to a direct gateway command" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 2,
        "chat" => %{"id" => 3, "type" => "private"},
        "from" => %{"id" => 4, "is_bot" => false},
        "text" => "/status"
      }
    }

    assert {:direct_command, %{name: "status", args: ""}} = UpdateMapper.map(update, source)
  end

  test "keeps unknown slash commands as command events" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      attention: default_attention()
    }

    update = %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 2,
        "chat" => %{"id" => 3, "type" => "private"},
        "from" => %{"id" => 4, "is_bot" => false},
        "text" => "/does_not_exist arg"
      }
    }

    assert {:ok, %{attrs: attrs}} = UpdateMapper.map(update, source)
    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "does_not_exist"
    assert attrs.data.command.args_text == "arg"
  end

  test "UTF-16 splitting respects emoji code units" do
    assert ["😀😀", "😀"] = ContentMapper.split_text("😀😀😀", 4)
  end
end
