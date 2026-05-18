defmodule Discord.EventMapperTest do
  use ExUnit.Case, async: true

  alias Discord.{ContentMapper, EventMapper, Source}

  test "maps a mentioned Discord message into CloudEvent attrs" do
    source = %Source{
      id: "main",
      application_id: "app_1",
      bot_token: "token",
      bot_user_id: "bot_1",
      connected_realm_ref: "discord:application:app_1"
    }

    payload = %{
      "id" => "msg_1",
      "channel_id" => "chan_1",
      "guild_id" => "guild_1",
      "timestamp" => "2026-05-17T10:00:00Z",
      "content" => "<@bot_1> hello",
      "mentions" => [%{"id" => "bot_1"}],
      "author" => %{"id" => "user_1", "username" => "Alice"}
    }

    assert {:ok, %{attrs: attrs, account_input: account_input}} =
             EventMapper.map({"message_create", payload}, source)

    assert attrs.type == "bullx.message.created"
    assert attrs.source == "discord://main/application/app_1"
    assert get_in(attrs.data, [:channel, :adapter]) == "discord"
    assert get_in(attrs.data, [:actor, :id]) == "discord:user_1"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "mention"
    assert [%{"kind" => "text", "body" => %{"text" => "hello"}}] = attrs.data.content
    assert account_input["external_id"] == "discord:user_1"
  end

  test "normalizes slash command text" do
    source = %Source{id: "main", application_id: "app_1", bot_token: "token"}

    payload = %{
      "id" => "msg_1",
      "channel_id" => "dm_1",
      "content" => "/status",
      "author" => %{"id" => "user_1", "username" => "Alice"}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map({"message_create", payload}, source)
    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "status"
  end

  test "UTF-16 splitting respects emoji code units" do
    assert ["😀", "😀"] = ContentMapper.split_text("😀😀", 2)
  end
end
