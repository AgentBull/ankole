defmodule Feishu.EventMapperTest do
  use ExUnit.Case, async: true

  alias Feishu.{EventMapper, Source}
  alias FeishuOpenAPI.{CardAction, Event}

  test "maps a Feishu message into IMGateway CloudEvent attrs" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      tenant_key: "tenant_x",
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
          "name" => "Ada",
          "avatar" => %{"avatar_240" => "https://example.com/avatar.png"}
        }
      },
      raw: %{"raw" => "not copied"}
    }

    assert {:ok, %{attrs: attrs, account_input: account_input}} = EventMapper.map(event, source)

    assert attrs.type == "bullx.message.received"
    assert attrs.source == "feishu://main/tenant_x"
    assert get_in(attrs.data, [:channel, :adapter]) == "feishu"
    assert get_in(attrs.data, [:channel, :id]) == "main"
    assert get_in(attrs.data, [:channel, :kind]) == "dm"
    assert get_in(attrs.data, [:actor, :external_account_id]) == "feishu:ou_user"
    assert get_in(attrs.data, [:actor, :display_name]) == "Ada"
    assert get_in(attrs.data, [:actor, :avatar_url]) == "https://example.com/avatar.png"
    assert get_in(attrs.data, [:actor, :principal]) == nil
    assert get_in(attrs.data, [:routing_facts, "group_message_mode"]) == "addressed_only"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "dm"
    assert get_in(attrs.data, [:reply_address, :delivery_mode]) == "stream"
    refute inspect(attrs.data.raw_ref) =~ "not copied"

    assert {:ok, message_event} = BullX.IMGateway.ChannelAdapter.build_message_event(attrs)
    assert get_in(message_event, ["data", "reply_address", "delivery_mode"]) == "stream"

    assert account_input["adapter"] == "feishu"
    assert account_input["channel_id"] == "main"
    assert account_input["external_id"] == "feishu:ou_user"
    assert get_in(account_input, ["profile", "avatar_url"]) == "https://example.com/avatar.png"
  end

  test "status is handled as an adapter-local direct command" do
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

    assert {:direct_command,
            %{
              name: "status",
              args: "",
              reply_address: %{
                adapter: "feishu",
                channel_id: "main",
                scope_id: "oc_chat",
                scope_kind: "dm",
                chat_type: "p2p",
                delivery_mode: "stream"
              }
            }} = EventMapper.map(event, source)
  end

  test "localized status alias maps to a direct command" do
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

    assert {:direct_command, %{name: "status", args: ""}} =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn -> EventMapper.map(event, source) end)
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
    assert attrs.data.command.name == "new"
    assert attrs.data.command.args_text == ""
  end

  test "unknown slash commands are delivered as command mail" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_unknown_command",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/does_not_exist arg"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)

    assert attrs.type == "bullx.command.invoked"
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "does_not_exist"
    assert attrs.data.command.args_text == "arg"
  end

  test "root_init remains an adapter-local direct command" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_root_init",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/root_init CODE"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:direct_command, %{name: "root_init", args: "CODE"}} =
             EventMapper.map(event, source)
  end

  test "webauth remains an adapter-local direct command" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_webauth",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/webauth"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:direct_command, %{name: "webauth", args: ""}} =
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
    assert attrs.type == "bullx.message.received"
    assert get_in(attrs.data, [:routing_facts, "action_id"]) == "approve"
    assert get_in(attrs.data, [:routing_facts, "action_actor_open_id"]) == "ou_user"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "action"

    assert [
             %{
               "type" => "action",
               "text" => "submitted action: approve",
               "action_id" => "approve",
               "values" => %{"decision" => "yes", "count" => 2}
             }
           ] = attrs.data.content
  end

  test "maps clarify card choices as prompt-visible action answers" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    action = %CardAction{
      open_id: "ou_user",
      open_message_id: "om_card",
      open_chat_id: "oc_chat",
      tenant_key: "tenant_x",
      action: %{
        "tag" => "button",
        "value" => %{
          "bullx_action" => "clarify_answer",
          "correlation_id" => "call_1",
          "choice_index" => 1,
          "choice_value" => "Beta",
          "drop" => nil
        }
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map({:card_action, action}, source)

    assert attrs.id == "card_action:om_card:clarify_answer:ou_user"
    assert attrs.type == "bullx.message.received"
    assert get_in(attrs.data, [:routing_facts, "action_id"]) == "clarify_answer"

    assert [
             %{
               "type" => "action",
               "text" => "Clarification answer: Beta",
               "action_id" => "clarify_answer",
               "values" => %{
                 "bullx_action" => "clarify_answer",
                 "correlation_id" => "call_1",
                 "choice_index" => 1,
                 "choice_value" => "Beta"
               }
             }
           ] = attrs.data.content
  end

  test "ignores bot sender messages" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x"
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
          "sender_id" => %{"user_id" => "u_other_bot"},
          "sender_type" => "bot"
        }
      },
      raw: %{}
    }

    assert {:ignore, :self_sent_bot_message} = EventMapper.map(event, source)
  end

  test "ignores unsupported message types instead of delivering fallback text" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_unsupported_message",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_unsupported",
          "message_type" => "share_chat",
          "content" => Jason.encode!(%{})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ignore, :unsupported_message} = EventMapper.map(event, source)
  end

  test "ignores empty text messages instead of delivering unsupported fallback text" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}

    event = %Event{
      id: "evt_empty_text",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "p2p",
          "message_id" => "om_empty_text",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "   "})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ignore, :unsupported_message} = EventMapper.map(event, source)
  end

  test "addressed_only ignores unmentioned group messages" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :addressed_only
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

  test "engage_all emits unmentioned group messages as ambient" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :engage_all
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
    assert attrs.type == "bullx.message.received"
    assert get_in(attrs.data, [:routing_facts, "group_message_mode"]) == "engage_all"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "unaddressed"
  end

  test "engage_all ignores unmentioned group slash commands" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :engage_all
    }

    event = %Event{
      id: "evt_ambient_command",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "/new"})
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ignore, :unaddressed_group_command} = EventMapper.map(event, source)
  end

  test "group messages with provider mention metadata are normalized as addressed" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :addressed_only
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
          "content" => Jason.encode!(%{text: "@_user_1 hello"}),
          "mentions" => [
            %{"key" => "@_user_1", "name" => "AgentBull", "id" => %{"open_id" => "ou_bot"}}
          ]
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)
    assert attrs.type == "bullx.message.received"
    assert attrs.data.content == [%{"type" => "text", "text" => "hello"}]
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "mention"
  end

  test "leading provider mention placeholder is stripped before command detection" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :addressed_only
    }

    event = %Event{
      id: "evt_mention_command",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "@_user_1 /status"}),
          "mentions" => [
            %{"key" => "_user_1", "name" => "AgentBull", "id" => %{"open_id" => "ou_bot"}}
          ]
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:direct_command, %{name: "status", args: ""}} = EventMapper.map(event, source)
  end

  test "provider mention text can invoke a known command without a slash" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :addressed_only
    }

    event = %Event{
      id: "evt_mention_retry",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "@_user_1 retry"}),
          "mentions" => [
            %{"key" => "_user_1", "name" => "AgentBull", "id" => %{"open_id" => "ou_bot"}}
          ]
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)

    assert attrs.type == "bullx.command.invoked"
    assert attrs.data.content == [%{"type" => "text", "text" => "retry"}]
    assert get_in(attrs.data, [:routing_facts, "command_name"]) == "retry"
    assert get_in(attrs.data, [:routing_facts, "command_surface"]) == "mention_text"
    assert get_in(attrs.data, [:routing_facts, "attention_reason"]) == "mention_text"
  end

  test "provider mention text with command-like leading word and arguments remains a message" do
    source = %Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      group_message_mode: :addressed_only
    }

    event = %Event{
      id: "evt_mention_retry_sentence",
      type: "im.message.receive_v1",
      content: %{
        "message" => %{
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_id" => "om_msg",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "@_user_1 retry the failed task"}),
          "mentions" => [
            %{"key" => "_user_1", "name" => "AgentBull", "id" => %{"open_id" => "ou_bot"}}
          ]
        },
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}}
      },
      raw: %{}
    }

    assert {:ok, %{attrs: attrs}} = EventMapper.map(event, source)

    assert attrs.type == "bullx.message.received"
    assert attrs.data.content == [%{"type" => "text", "text" => "retry the failed task"}]
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
