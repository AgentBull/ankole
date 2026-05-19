defmodule Feishu.EventMapperTest do
  use ExUnit.Case, async: true

  alias Feishu.{EventMapper, Source}
  alias FeishuOpenAPI.{CardAction, Event}

  test "maps a Feishu message into EventBus CloudEvent attrs" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      tenant_key: "tenant_x",
      connected_realm_ref: "feishu:tenant:acme",
      inline_media_max_bytes: 0
    }

    event = %Event{
      id: "evt_1",
      type: "im.message.receive_v1",
      tenant_key: "tenant_x",
      app_id: "cli_x",
      created_at: ~U[2026-05-18 01:02:03Z],
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "hello"})
        },
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_user"},
          "sender_type" => "user",
          "name" => "Ada"
        }
      },
      raw: %{"raw" => "not copied"}
    }

    assert {:ok, %{attrs: attrs, account_input: account_input}} = EventMapper.map(event, source)

    assert attrs.type == "bullx.im.message.addressed"
    assert attrs.source == "feishu://main/tenant_x"
    assert get_in(attrs.data, [:channel, :adapter]) == "feishu"
    assert get_in(attrs.data, [:channel, :id]) == "main"
    assert get_in(attrs.data, [:channel, :kind]) == "dm"
    assert get_in(attrs.data, [:actor, :external_account_id]) == "feishu:ou_user"
    assert get_in(attrs.data, [:actor, :display_name]) == "Ada"
    assert get_in(attrs.data, [:actor, :principal]) == nil
    assert get_in(attrs.data, [:routing_facts, "connected_realm_ref"]) == "feishu:tenant:acme"
    assert get_in(attrs.data, [:routing_facts, "im_listen_mode"]) == "addressed_only"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "dm"
    refute inspect(attrs.data.raw_ref) =~ "not copied"

    assert account_input["adapter"] == "feishu"
    assert account_input["channel_id"] == "main"
    assert account_input["external_id"] == "feishu:ou_user"
  end

  test "status is normalized as a command event instead of adapter-local direct command" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_status",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/status"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)

    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "status"
    assert get_in(attrs.data, [:reply_channel, :scope_id]) == "oc_chat"
  end

  test "localized status alias is normalized to the canonical command name" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_status_zh",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/状态"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> EventMapper.map(event, source) end)

    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "status"
  end

  test "localized new-conversation alias is normalized to the canonical ai agent command name" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_new_zh",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/新会话"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> EventMapper.map(event, source) end)

    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "new"
  end

  test "preauth remains an adapter-local direct command" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_preauth",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/preauth CODE"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:direct_command, %{name: "preauth", args: "CODE"}} =
             EventMapper.map(event, source)
  end

  test "maps card actions with stable fallback ids and sanitized action values" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    action = %CardAction{
      open_id: "ou_user",
      user_id: "u_user",
      open_message_id: "om_card",
      open_chat_id: "oc_chat",
      tenant_key: "tenant_x",
      action: %{
        "tag" => "approve",
        "value" => %{"decision" => "yes", "count" => 2, "drop" => nil}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map({:card_action, action}, source)

    assert attrs.id == "card_action:om_card:approve:ou_user"
    assert attrs.type == "bullx.action.submitted"
    assert get_in(attrs.data, [:routing_facts, "action_id"]) == "approve"
    assert get_in(attrs.data, [:routing_facts, "action_actor_open_id"]) == "ou_user"

    assert [
             %{
               "type" => "action",
               "text" => "submitted action: approve",
               "action_id" => "approve",
               "values" => %{"decision" => "yes", "count" => 2}
             }
           ] = attrs.data.content
  end

  test "ignores self-sent bot messages by bot_user_id" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      bot_user_id: "u_bot"
    }

    event = %Event{
      id: "evt_bot",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_bot",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "bot echo"})
        },
        "sender" => %{
          "sender_id" => %{"user_id" => "u_bot"},
          "sender_type" => "bot"
        }
      },
      raw: %{}
    }

    assert {:ignore, :self_sent_bot_message} = EventMapper.map(event, source)
  end

  test "addressed_only ignores unmentioned group messages" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      bot_open_id: "ou_bot",
      im_listen_mode: :addressed_only
    }

    event = %Event{
      id: "evt_group",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "casual chatter"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ignore, :unaddressed_group_message} = EventMapper.map(event, source)
  end

  test "all_messages emits unmentioned group messages as ambient" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      bot_open_id: "ou_bot",
      im_listen_mode: :all_messages
    }

    event = %Event{
      id: "evt_ambient",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "casual chatter"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)
    assert attrs.type == "bullx.im.message.ambient"
    assert get_in(attrs.data, [:routing_facts, "im_listen_mode"]) == "all_messages"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "unaddressed"
  end

  test "group messages that mention the bot are normalized as addressed" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      bot_open_id: "ou_bot",
      im_listen_mode: :addressed_only
    }

    event = %Event{
      id: "evt_mention",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "@bullx hello"}),
          "mentions" => [%{"id" => %{"open_id" => "ou_bot"}}]
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)
    assert attrs.type == "bullx.im.message.addressed"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "mention"
  end

  test "reaction events with blank emoji fail closed" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_reaction",
      type: "im.message.reaction.created_v1",
      content: %{
        "message_id" => "om_msg",
        "chat_id" => "oc_chat",
        "reaction" => %{"emoji_type" => ""},
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:error, %{"kind" => "payload"}} = EventMapper.map(event, source)
  end
end
