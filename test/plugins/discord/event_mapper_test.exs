defmodule Discord.EventMapperTest do
  use ExUnit.Case, async: true

  alias Discord.{EventMapper, Source}

  defp source(overrides \\ %{}) do
    base = %{
      adapter: "discord",
      channel_id: "main",
      application_id: "111",
      bot_user_id: "9999",
      attention: %{
        "allowed_channel_ids" => [],
        "ignored_channel_ids" => [],
        "ignored_thread_ids" => [],
        "require_mention" => true,
        "free_response_channel_ids" => []
      },
      auto_thread: %{
        "enabled" => true,
        "auto_archive_duration_minutes" => 1440,
        "no_thread_channel_ids" => []
      }
    }

    struct!(Source, Map.merge(base, overrides))
  end

  defp dm_message(content) do
    %{
      "id" => "msg_1",
      "channel_id" => "dm1",
      "guild_id" => nil,
      "content" => content,
      "author" => %{"id" => "42", "username" => "alice", "global_name" => "Alice"}
    }
  end

  defp guild_mention_message(content) do
    %{
      "id" => "msg_2",
      "channel_id" => "ch_42",
      "guild_id" => "guild_1",
      "content" => content,
      "author" => %{"id" => "42", "username" => "alice"},
      "mentions" => [%{"id" => "9999"}]
    }
  end

  test "DM text message maps to a Gateway message input" do
    assert {:ok, mapped} = EventMapper.map_event(dm_message("hello"), "message_create", source())

    assert mapped.input["adapter"] == "discord"
    assert mapped.input["channel_id"] == "main"
    assert mapped.input["scope_id"] == "dm1"
    assert mapped.input["event"]["type"] == "message"
    assert mapped.input["event"]["name"] == "discord.message_create"
    assert get_in(mapped.input, ["event", "data", "attention_reason"]) == "dm"
    refute mapped.auto_thread?
    assert is_nil(mapped.interaction)
    assert mapped.account_input["external_id"] == "discord:42"
  end

  test "DM /ping intercepts as direct command" do
    assert {:direct_command, command} =
             EventMapper.map_event(dm_message("/ping"), "message_create", source())

    assert command.name == "ping"
    assert command.transport == :message
    assert command.dm?
  end

  test "guild mention is mapped and flagged for auto-thread when enabled" do
    assert {:ok, mapped} =
             EventMapper.map_event(
               guild_mention_message("<@9999> hi"),
               "message_create",
               source()
             )

    assert get_in(mapped.input, ["event", "data", "attention_reason"]) == "mention"
    assert mapped.auto_thread?
  end

  test "MESSAGE_UPDATE with edited_timestamp maps as message_edited" do
    message = %{
      "id" => "msg_2",
      "channel_id" => "dm1",
      "guild_id" => nil,
      "content" => "edited",
      "edited_timestamp" => "2026-05-14T00:00:00Z",
      "author" => %{"id" => "42", "username" => "alice"}
    }

    assert {:ok, mapped} = EventMapper.map_event(message, "message_update", source())
    assert mapped.input["event"]["type"] == "message_edited"
    assert mapped.input["event"]["name"] == "discord.message_update"
    assert get_in(mapped.input, ["event", "data", "target_external_id"]) == "msg_2"
    refute mapped.auto_thread?

    assert mapped.input["occurrence_key"] ==
             "discord:main:edit:msg_2:2026-05-14T00:00:00Z"
  end

  test "MESSAGE_UPDATE without edited_timestamp is ignored as non_user_edit" do
    message = %{
      "id" => "msg_2",
      "channel_id" => "dm1",
      "guild_id" => nil,
      "content" => "still",
      "author" => %{"id" => "42", "username" => "alice"}
    }

    assert {:ignore, :non_user_edit} = EventMapper.map_event(message, "message_update", source())
  end

  test "self bot message is dropped" do
    message = %{
      "id" => "msg_3",
      "channel_id" => "dm1",
      "guild_id" => nil,
      "content" => "echo",
      "author" => %{"id" => "9999", "bot" => true}
    }

    assert {:ignore, :bot_author} = EventMapper.map_event(message, "message_create", source())
  end

  test "webhook author is dropped" do
    message = %{
      "id" => "msg_4",
      "channel_id" => "dm1",
      "guild_id" => nil,
      "content" => "hook",
      "author" => %{"id" => "42", "username" => "alice"},
      "webhook_id" => "wh_1"
    }

    assert {:ignore, :webhook_author} = EventMapper.map_event(message, "message_create", source())
  end

  test "/ask interaction maps to slash_command input with auto_thread flag" do
    interaction = %{
      "id" => "int_1",
      "channel_id" => "ch_42",
      "guild_id" => "guild_1",
      "type" => 2,
      "user" => %{"id" => "42", "username" => "alice"},
      "data" => %{"name" => "ask", "options" => [%{"name" => "prompt", "value" => "do x"}]}
    }

    assert {:ok, mapped} = EventMapper.map_event(interaction, "interaction_create", source())

    assert mapped.input["event"]["type"] == "slash_command"
    assert get_in(mapped.input, ["event", "data", "command_name"]) == "ask"
    assert get_in(mapped.input, ["event", "data", "args"]) == "do x"
    assert mapped.auto_thread?
    assert mapped.interaction == interaction
  end

  test "ping interaction maps to direct command with interaction transport" do
    interaction = %{
      "id" => "int_2",
      "channel_id" => "dm1",
      "guild_id" => nil,
      "type" => 2,
      "user" => %{"id" => "42", "username" => "alice"},
      "data" => %{"name" => "ping"}
    }

    assert {:direct_command, command} =
             EventMapper.map_event(interaction, "interaction_create", source())

    assert command.name == "ping"
    assert command.transport == :interaction
    assert command.interaction == interaction
  end

  test "/ask with empty prompt returns payload error" do
    interaction = %{
      "id" => "int_3",
      "channel_id" => "ch_42",
      "guild_id" => "guild_1",
      "type" => 2,
      "user" => %{"id" => "42"},
      "data" => %{"name" => "ask", "options" => [%{"name" => "prompt", "value" => ""}]}
    }

    assert {:error, %{"kind" => "payload"}} =
             EventMapper.map_event(interaction, "interaction_create", source())
  end

  test "non-application-command interaction is ignored" do
    interaction = %{
      "id" => "int_4",
      "channel_id" => "dm1",
      "type" => 3,
      "user" => %{"id" => "42"}
    }

    assert {:ignore, :unsupported_interaction} =
             EventMapper.map_event(interaction, "interaction_create", source())
  end
end
