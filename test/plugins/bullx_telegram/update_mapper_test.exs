defmodule BullxTelegram.UpdateMapperTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.{ContentMapper, Source, UpdateMapper}

  test "maps a private Telegram text update into CloudEvent attrs" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      connected_realm_ref: "telegram:bot:123456"
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

    assert attrs.type == "bullx.message.created"
    assert attrs.source == "telegram://main/bot/123456"
    assert get_in(attrs.data, [:channel, :adapter]) == "telegram"
    assert get_in(attrs.data, [:scope, :id]) == "987654321"
    assert get_in(attrs.data, [:actor, :id]) == "telegram:987654321"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "dm"
    assert account_input["external_id"] == "telegram:987654321"
  end

  test "normalizes localized command aliases to command events" do
    source = %Source{
      id: "main",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot"
    }

    update = %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 2,
        "chat" => %{"id" => 3, "type" => "private"},
        "from" => %{"id" => 4, "is_bot" => false},
        "text" => "/状态"
      }
    }

    assert {:ok, %{attrs: attrs}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> UpdateMapper.map(update, source) end)

    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "status"
  end

  test "UTF-16 splitting respects emoji code units" do
    assert ["😀😀", "😀"] = ContentMapper.split_text("😀😀😀", 4)
  end
end
