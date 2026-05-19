defmodule Discord.EventMapperTest do
  use ExUnit.Case, async: true

  alias Discord.{ContentMapper, EventMapper, Source}

  defp default_attention do
    %{
      "allowed_channel_ids" => [],
      "ignored_channel_ids" => [],
      "ignored_thread_ids" => [],
      "require_mention" => true,
      "free_response_channel_ids" => []
    }
  end

  test "maps a mentioned Discord message into CloudEvent attrs" do
    source = %Source{
      id: "main",
      application_id: "app_1",
      bot_token: "token",
      bot_user_id: "bot_1",
      connected_realm_ref: "discord:application:app_1",
      attention: default_attention()
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

    assert attrs.type == "bullx.im.message.addressed"
    assert attrs.source == "discord://main/application/app_1"
    assert get_in(attrs.data, [:channel, :adapter]) == "discord"
    assert get_in(attrs.data, [:channel, :kind]) == "group"
    assert get_in(attrs.data, [:actor, :external_account_id]) == "discord:user_1"
    assert get_in(attrs.data, [:actor, :display_name]) == "Alice"
    assert get_in(attrs.data, [:actor, :principal]) == nil
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "mention"
    assert get_in(attrs.data, [:routing_facts, "im_listen_mode"]) == "addressed_only"
    assert [%{"type" => "text", "text" => "hello"}] = attrs.data.content
    assert account_input["external_id"] == "discord:user_1"
  end

  test "normalizes slash command text" do
    source = %Source{
      id: "main",
      application_id: "app_1",
      bot_token: "token",
      attention: default_attention()
    }

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

  test "normalizes application command ask prompt into command content" do
    source = %Source{
      id: "main",
      application_id: "app_1",
      bot_token: "token",
      attention: default_attention()
    }

    payload = %{
      "id" => "interaction_1",
      "type" => 2,
      "channel_id" => "chan_1",
      "guild_id" => "guild_1",
      "data" => %{
        "id" => "command_ask",
        "name" => "ask",
        "options" => [%{"name" => "prompt", "value" => "summarize this"}]
      },
      "member" => %{"user" => %{"id" => "user_1", "username" => "Alice"}}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map({"interaction_create", payload}, source)
    assert attrs.type == "bullx.command.invoked"
    assert [%{"type" => "text", "text" => "summarize this"}] = attrs.data.content
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "ask"
    assert get_in(attrs.data, [:routing_facts, "command_surface"]) == "provider_native"
  end

  test "ignores non application-command interactions" do
    source = %Source{id: "main", application_id: "app_1", bot_token: "token"}

    payload = %{
      "id" => "interaction_autocomplete",
      "type" => 4,
      "data" => %{"name" => "ask", "options" => [%{"name" => "prompt", "value" => "x"}]}
    }

    assert {:ignore, :unsupported_interaction} =
             EventMapper.map({"interaction_create", payload}, source)
  end

  test "ignores ask interactions without prompt option" do
    source = %Source{id: "main", application_id: "app_1", bot_token: "token"}

    payload = %{
      "id" => "interaction_missing_prompt",
      "type" => 2,
      "data" => %{"name" => "ask", "options" => []}
    }

    assert {:ignore, :missing_required_prompt} =
             EventMapper.map({"interaction_create", payload}, source)
  end

  test "all_messages emits unmentioned guild messages as ambient" do
    source = %Source{
      id: "main",
      application_id: "app_1",
      bot_token: "token",
      bot_user_id: "bot_1",
      attention: default_attention(),
      im_listen_mode: :all_messages
    }

    payload = %{
      "id" => "msg_amb",
      "channel_id" => "chan_1",
      "guild_id" => "guild_1",
      "timestamp" => "2026-05-17T10:00:00Z",
      "content" => "no mention here",
      "author" => %{"id" => "user_1", "username" => "Alice"}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map({"message_create", payload}, source)
    assert attrs.type == "bullx.im.message.ambient"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "unaddressed"
    assert get_in(attrs.data, [:routing_facts, "im_listen_mode"]) == "all_messages"
  end

  test "addressed_only ignores unmentioned guild messages" do
    source = %Source{
      id: "main",
      application_id: "app_1",
      bot_token: "token",
      bot_user_id: "bot_1",
      attention: default_attention()
    }

    payload = %{
      "id" => "msg_skip",
      "channel_id" => "chan_1",
      "guild_id" => "guild_1",
      "content" => "no mention",
      "author" => %{"id" => "user_1", "username" => "Alice"}
    }

    assert {:ignore, :unmentioned_guild_message} =
             EventMapper.map({"message_create", payload}, source)
  end

  test "UTF-16 splitting respects emoji code units" do
    assert ["😀", "😀"] = ContentMapper.split_text("😀😀", 2)
  end

  test "attachment fallback ignores blank filenames" do
    source = %Source{id: "main", application_id: "app_1", bot_token: "token"}

    message = %{
      "id" => "msg_media",
      "channel_id" => "chan_1",
      "content" => "",
      "attachments" => [
        %{"id" => "attachment_1", "filename" => "", "content_type" => "image/png"},
        %{"id" => "attachment_2", "filename" => "voice.mp3", "content_type" => "audio/mpeg"}
      ]
    }

    assert {:ok,
            [
              %{
                "type" => "image_url",
                "fallback_text" => "[image]",
                "media_type" => "image/png"
              },
              %{
                "type" => "file",
                "fallback_text" => "voice.mp3",
                "media_type" => "audio/mpeg"
              }
            ]} =
             ContentMapper.from_message(message, source)
  end
end
