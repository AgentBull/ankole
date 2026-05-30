defmodule BullX.IMGatewayTest do
  use BullX.DataCase, async: false

  import Ecto.Query

  alias BullX.AIAgent.Conversation
  alias BullX.AIAgent.Message, as: AgentMessage
  alias BullX.IMGateway
  alias BullX.IMGateway.Message
  alias BullX.MailBox.{DeliveryRule, Entry}
  alias BullX.Principals.{Agent, ExternalIdentity, Principal}
  alias BullX.Repo

  setup do
    BullX.Cache.clear()
    on_exit(fn -> BullX.Cache.clear() end)
    :ok
  end

  test "accept_message_event stores an IM message, creates human Principal, and routes mailbox entry" do
    insert_delivery_rule!("im received")

    assert {:ok, %{message: %Message{} = message}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-1",
                 "om_1",
                 "hello",
                 true,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
               )
             )

    message = Repo.preload(message, :room)

    assert message.lifecycle_state == :active
    assert message.provider_message_id == "om_1"
    assert message.actor_kind == "human"
    assert message.actor_provider_id == "feishu:user_id:user_x"
    refute Map.has_key?(message.actor, "principal")

    assert %ExternalIdentity{kind: :channel_actor, principal: %Principal{type: :human}} =
             Repo.one!(
               from identity in ExternalIdentity,
                 where: identity.adapter == "feishu",
                 where: identity.channel_id == "main",
                 where: identity.external_id == "feishu:user_id:user_x",
                 preload: [:principal]
             )

    assert message.room.provider == "feishu"
    assert message.room.provider_realm_id == "tenant"
    assert message.room.provider_room_id == "chat_1"

    entry = Repo.one!(Entry) |> Repo.preload([:agent, :session])
    assert entry.attention == :ambient
    assert entry.cloud_event["type"] == "bullx.message.received"

    assert entry.cloud_event["data"]["source_fact"] == %{
             "gateway" => "im_gateway",
             "kind" => "im_message",
             "id" => "om_1",
             "room_key" => "im://feishu/main/chat_1",
             "provider_message_id" => "om_1",
             "provider_occurrence_id" => "evt-1",
             "event_type" => "bullx.message.received"
           }

    assert get_in(entry.cloud_event, ["data", "conversation_context", "scene"]) == %{
             "kind" => "im",
             "channel_adapter" => "feishu",
             "channel_id" => "main",
             "channel_kind" => "group",
             "scope_id" => "chat_1",
             "thread_id" => ""
           }

    assert entry.agent.type == :ai_agent
  end

  test "mailbox runtime tables are unlogged" do
    rows =
      Repo.all(
        from c in "pg_class",
          where: field(c, :relname) in ["mailbox_entries", "mailbox_sessions"],
          select: {field(c, :relname), field(c, :relpersistence)}
      )
      |> Map.new()

    assert rows["mailbox_entries"] == "u"
    assert rows["mailbox_sessions"] == "u"
  end

  test "unverified addressed messages are stored without MailBox delivery" do
    insert_delivery_rule!("im received")

    assert {:ok, %{message: %Message{} = message, mailbox: :skipped_unverified_actor}} =
             IMGateway.accept_message_event(
               im_message_event("evt-unverified", "om_unverified", "hello", false)
             )

    identity =
      Repo.one!(
        from identity in ExternalIdentity,
          where: identity.adapter == "feishu",
          where: identity.channel_id == "main",
          where: identity.external_id == "feishu:user_id:user_x"
      )

    assert message.actor_provider_id == "feishu:user_id:user_x"
    refute BullX.Principals.channel_identity_verified?(identity)
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "ambient messages from unverified actors still route through MailBox" do
    insert_delivery_rule!("im received")

    assert {:ok, %{message: %Message{} = message, mailbox: _mailbox}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-unverified-ambient",
                 "om_unverified_ambient",
                 "background",
                 false,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
               )
             )

    identity =
      Repo.one!(
        from identity in ExternalIdentity,
          where: identity.adapter == "feishu",
          where: identity.channel_id == "main",
          where: identity.external_id == "feishu:user_id:user_x"
      )

    assert message.actor_provider_id == "feishu:user_id:user_x"
    refute BullX.Principals.channel_identity_verified?(identity)
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "message edit facts route as source-neutral lifecycle mail" do
    insert_delivery_rule!("message edit", ~s(type == "bullx.message.edited"))

    event =
      "evt-edit"
      |> im_message_event("om_edit", "edited")
      |> Map.put("type", "bullx.message.edited")

    assert {:ok, %{message: %Message{} = message, mailbox: [_result]}} =
             IMGateway.accept_message_event(event)

    assert message.lifecycle_state == :edited

    entry = Repo.one!(Entry)
    assert entry.cloud_event["type"] == "bullx.message.edited"
    assert get_in(entry.cloud_event, ["data", "source_fact", "revision", "action"]) == "edited"
    assert_entry_status(entry.id, :processed)
  end

  test "message lifecycle routes even when edited content is no longer addressed" do
    insert_delivery_rule!("message edit unaddressed", ~s(type == "bullx.message.edited"))

    event =
      "evt-edit-unaddressed"
      |> im_message_event(
        "om_edit_unaddressed",
        "never mind",
        true,
        %{"attention_reason" => "unaddressed", "group_message_mode" => "addressed_only"}
      )
      |> Map.put("type", "bullx.message.edited")

    assert {:ok, %{message: %Message{} = message, mailbox: [_result]}} =
             IMGateway.accept_message_event(event)

    assert message.lifecycle_state == :edited

    entry = Repo.one!(Entry)
    assert entry.cloud_event["type"] == "bullx.message.edited"
    assert_entry_status(entry.id, :processed)
  end

  test "message delete facts route as source-neutral lifecycle mail" do
    insert_delivery_rule!("message delete", ~s(type == "bullx.message.deleted"))

    event =
      "evt-delete"
      |> im_message_event("om_delete", "deleted")
      |> Map.put("type", "bullx.message.deleted")

    assert {:ok, %{message: %Message{} = message, mailbox: [_result]}} =
             IMGateway.accept_message_event(event)

    assert message.lifecycle_state == :deleted

    entry = Repo.one!(Entry)
    assert entry.cloud_event["type"] == "bullx.message.deleted"
    assert get_in(entry.cloud_event, ["data", "source_fact", "revision", "action"]) == "deleted"
    assert_entry_status(entry.id, :processed)
  end

  test "terminal lifecycle tombstone suppresses late receive without mirror dependency" do
    insert_delivery_rule!("message delete terminal", ~s(type == "bullx.message.deleted"))
    insert_delivery_rule!("message received after terminal")

    delete_event =
      "evt-terminal-delete"
      |> im_message_event("om_terminal", "deleted")
      |> Map.put("type", "bullx.message.deleted")

    assert {:ok, %{message: %Message{lifecycle_state: :deleted}}} =
             IMGateway.accept_message_event(delete_event)

    query = from message in Message, where: message.provider_message_id == "om_terminal"

    assert {1, _rows} = Repo.delete_all(query)

    late_received =
      im_message_event("evt-terminal-received", "om_terminal", "late received after delete")

    assert {:ok,
            %{
              message: nil,
              mailbox: :skipped_terminal_lifecycle_message
            }} = IMGateway.accept_message_event(late_received)

    assert Repo.aggregate(Entry, :count) == 1
    assert Repo.aggregate(query, :count) == 0
  end

  test "terminal mirror row alone does not suppress received delivery" do
    insert_delivery_rule!("message received after terminal mirror")

    delete_event =
      "evt-terminal-mirror-only-delete"
      |> im_message_event("om_terminal_mirror_only", "deleted")
      |> Map.put("type", "bullx.message.deleted")

    assert {:ok, %{message: %Message{lifecycle_state: :deleted}}} =
             IMGateway.accept_message_event(delete_event)

    BullX.Cache.clear()

    late_received =
      im_message_event(
        "evt-terminal-mirror-only-received",
        "om_terminal_mirror_only",
        "late received with mirror only"
      )

    assert {:ok,
            %{
              message: %Message{lifecycle_state: :deleted},
              mailbox: [ok: %{entry: %Entry{}}]
            }} = IMGateway.accept_message_event(late_received)
  end

  test "IMGateway to MailBox to AIAgent writes conversation message end to end" do
    {:ok, %{principal: agent}} =
      BullX.Principals.create_agent(%{
        uid: "imgateway-e2e-agent",
        display_name: "IMGateway E2E Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Observe IM messages.",
            "instructions" => "Record ambient context."
          }
        }
      })

    agent_uid = agent.uid
    insert_agent_delivery_rule!(agent_uid)

    assert {:ok, %{message: %Message{} = im_message}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-agent-1",
                 "om_agent_1",
                 "background",
                 true,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
               )
             )

    entry = Repo.one!(Entry)
    entry_id = entry.id
    assert entry.status == :pending

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)

    assert %Entry{status: :processed} = Repo.get!(Entry, entry_id)
    assert %Conversation{agent_uid: ^agent_uid} = Repo.one!(Conversation)

    assert %AgentMessage{
             role: :im_ambient,
             kind: :normal,
             status: :complete,
             content: [%{"type" => "text", "text" => "background"}],
             event_id: event_id
           } = Repo.one!(AgentMessage)

    assert event_id == "feishu://main/tenant:evt-agent-1:bullx.message.received"
    assert im_message.actor_provider_id == "feishu:user_id:user_x"
  end

  test "consecutive IM messages from one actor coalesce before AIAgent handling" do
    {:ok, %{principal: agent}} =
      BullX.Principals.create_agent(%{
        uid: "imgateway-coalesce-agent",
        display_name: "IMGateway Coalesce Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Observe IM messages.",
            "instructions" => "Record ambient context."
          }
        }
      })

    insert_agent_delivery_rule!(agent.uid)

    assert {:ok, %{message: %Message{}}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-coalesce-1",
                 "om_coalesce_1",
                 "first",
                 true,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
               )
             )

    assert {:ok, %{message: %Message{}}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-coalesce-2",
                 "om_coalesce_2",
                 "second",
                 true,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
               )
             )

    [first_entry, second_entry] =
      Entry
      |> order_by([entry], asc: entry.entry_seq)
      |> Repo.all()

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)

    assert %Entry{status: :processed} = Repo.get!(Entry, first_entry.id)
    assert %Entry{status: :processed} = Repo.get!(Entry, second_entry.id)

    assert [
             %AgentMessage{
               role: :im_ambient,
               kind: :normal,
               content: [%{"type" => "text", "text" => "first\nsecond"}],
               event_id: event_id
             }
           ] = Repo.all(AgentMessage)

    assert event_id == first_entry.cloud_event["id"]
  end

  test "coalesced group batch is addressed when any active item is addressed" do
    {:ok, %{principal: agent}} =
      BullX.Principals.create_agent(%{
        uid: "imgateway-coalesce-addressed-agent",
        display_name: "IMGateway Addressed Coalesce Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Handle addressed coalesce tests.",
            "instructions" => "Record user input."
          }
        }
      })

    insert_agent_delivery_rule!(agent.uid)

    assert {:ok, %{message: %Message{}}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-coalesce-addressed-1",
                 "om_coalesce_addressed_1",
                 "@agent first",
                 true,
                 %{"attention_reason" => "mention", "group_message_mode" => "engage_all"}
               )
             )

    assert {:ok, %{message: %Message{}}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-coalesce-addressed-2",
                 "om_coalesce_addressed_2",
                 "second",
                 true,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
               )
             )

    [first_entry, second_entry] =
      Entry
      |> order_by([entry], asc: entry.entry_seq)
      |> Repo.all()

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)

    assert %Entry{status: :processed} = Repo.get!(Entry, first_entry.id)
    assert %Entry{status: :processed} = Repo.get!(Entry, second_entry.id)

    assert %AgentMessage{
             role: :user,
             kind: :normal,
             content: [%{"type" => "text", "text" => "@agent first\nsecond"}],
             event_id: event_id,
             metadata: %{
               "im_batch" => %{
                 "effective_attention" => "addressed",
                 "items" => [_first, _second]
               }
             }
           } = Repo.get_by!(AgentMessage, role: :user, kind: :normal)

    assert event_id == first_entry.cloud_event["id"]
  end

  test "message edits inside the coalesce window rewrite the pending receive entry" do
    {:ok, %{principal: agent}} =
      BullX.Principals.create_agent(%{
        uid: "imgateway-pending-edit-agent",
        display_name: "IMGateway Pending Edit Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Record pending edit tests.",
            "instructions" => "Record user input."
          }
        }
      })

    insert_agent_delivery_rule!(agent.uid)
    insert_agent_delivery_rule!(agent.uid, ~s(type == "bullx.message.edited"))

    routing_facts = %{
      "attention_reason" => "unaddressed",
      "group_message_mode" => "engage_all"
    }

    assert {:ok, %{message: %Message{}}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-pending-edit-1",
                 "om_pending_edit",
                 "before edit",
                 true,
                 routing_facts
               )
             )

    edit_event =
      "evt-pending-edit-2"
      |> im_message_event("om_pending_edit", "after edit", true, routing_facts)
      |> Map.put("type", "bullx.message.edited")

    assert {:ok,
            %{
              message: %Message{},
              mailbox: [{:ok, %{entry: %Entry{id: edit_entry_id}}}]
            }} =
             IMGateway.accept_message_event(edit_event)

    assert_entry_status(edit_entry_id, :processed)

    [receive_entry, edit_entry] =
      Entry
      |> order_by([entry], asc: entry.entry_seq)
      |> Repo.all()

    assert %Entry{status: :pending} = receive_entry
    assert %Entry{status: :processed} = edit_entry

    assert get_in(receive_entry.cloud_event, ["data", "content"]) == [
             %{"type" => "text", "text" => "after edit"}
           ]

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)

    assert %AgentMessage{
             role: :im_ambient,
             kind: :normal,
             content: [%{"type" => "text", "text" => "after edit"}]
           } = Repo.one!(AgentMessage)
  end

  test "Feishu message maps through IMGateway, MailBox, and AIAgent" do
    {:ok, %{principal: agent}} =
      BullX.Principals.create_agent(%{
        uid: "feishu-imgateway-e2e-agent",
        display_name: "Feishu IMGateway E2E Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Observe Feishu group messages.",
            "instructions" => "Record ambient context."
          }
        }
      })

    insert_agent_delivery_rule!(agent.uid)

    source = %Feishu.Source{
      id: "main",
      app_id: "cli_x",
      app_secret: "secret_x",
      tenant_key: "tenant_x",
      group_message_mode: :engage_all
    }

    event = %FeishuOpenAPI.Event{
      id: "evt_feishu_e2e",
      type: "im.message.receive_v1",
      tenant_key: "tenant_x",
      app_id: "cli_x",
      created_at: ~U[2026-05-27 01:02:03Z],
      content: %{
        "message" => %{
          "chat_id" => "oc_group",
          "chat_type" => "group",
          "message_id" => "om_feishu_e2e",
          "message_type" => "text",
          "content" => Jason.encode!(%{text: "group background"})
        },
        "sender" => %{
          "sender_id" => %{"user_id" => "user_feishu_e2e", "open_id" => "ou_feishu_e2e"},
          "sender_type" => "user",
          "name" => "Feishu User"
        }
      },
      raw: %{"raw" => "not copied"}
    }

    assert {:ok, %{attrs: attrs}} = Feishu.EventMapper.map(event, source)
    assert {:ok, message_event} = BullX.IMGateway.ChannelAdapter.build_message_event(attrs)

    assert {:ok, %{message: %Message{} = im_message}} =
             IMGateway.accept_message_event(message_event)

    assert im_message.provider_message_id == "om_feishu_e2e"
    assert im_message.actor_provider_id == "feishu:user_id:user_feishu_e2e"

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)

    assert %AgentMessage{
             role: :im_ambient,
             kind: :normal,
             status: :complete,
             content: [%{"type" => "text", "text" => "group background"}]
           } = Repo.one!(AgentMessage)
  end

  test "human im_messages mirror rows can store unresolved provider actors" do
    room =
      %BullX.IMGateway.Room{}
      |> BullX.IMGateway.Room.changeset(%{
        provider: "feishu",
        provider_realm_id: "tenant",
        provider_room_id: "chat_2",
        kind: :group,
        metadata: %{}
      })
      |> Repo.insert!()

    assert {:ok, %Message{} = message} =
             %Message{}
             |> Message.changeset(%{
               room_id: room.id,
               lifecycle_state: :active,
               provider_message_id: "om_missing_principal",
               actor_kind: "human",
               actor_provider_id: "feishu:user_id:missing",
               actor: %{"external_account_id" => "feishu:user_id:missing"},
               message_kind: "text",
               content: %{},
               attachments: [],
               mentions: [],
               observed_at: DateTime.utc_now(:microsecond)
             })
             |> Repo.insert()

    assert message.actor_kind == "human"
    assert message.actor_provider_id == "feishu:user_id:missing"
  end

  test "observe_all unaddressed group messages route as ambient MailBox entries" do
    insert_delivery_rule!("observe only")

    assert {:ok, %{message: %Message{} = message, mailbox: [ok: %{entry: %Entry{} = entry}]}} =
             IMGateway.accept_message_event(
               im_message_event(
                 "evt-observe-only",
                 "om_observe_only",
                 "background",
                 true,
                 %{"attention_reason" => "unaddressed", "group_message_mode" => "observe_all"}
               )
             )

    assert message.lifecycle_state == :active
    assert entry.attention == :ambient
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "failed route does not mark inbound event as processed" do
    original_config = Application.get_env(:bullx, BullX.MailBox, [])

    :ok =
      Application.put_env(
        :bullx,
        BullX.MailBox,
        Keyword.put(original_config, :active_rules_cache_ttl_ms, 60_000)
      )

    BullX.MailBox.invalidate_delivery_rule_cache()

    on_exit(fn ->
      Application.put_env(:bullx, BullX.MailBox, original_config)
      BullX.MailBox.invalidate_delivery_rule_cache()
    end)

    agent_uid = ai_agent!("stale-route")
    insert_agent_delivery_rule!(agent_uid)
    assert {:ok, [_result]} = BullX.MailBox.route(warmup_mail("stale-route-warmup"))
    assert {1, _rows} = Repo.delete_all(from agent in Agent, where: agent.uid == ^agent_uid)

    event =
      im_message_event(
        "evt-route-error",
        "om_route_error",
        "retry me",
        true,
        %{"attention_reason" => "unaddressed", "group_message_mode" => "engage_all"}
      )

    assert {:error, {:delivery_failed, [{:error, :agent_not_found}]}} =
             IMGateway.accept_message_event(event)

    assert Repo.aggregate(Entry, :count) == 0

    BullX.MailBox.invalidate_delivery_rule_cache()
    insert_delivery_rule!("valid route after error")

    assert {:ok, %{message: %Message{}, mailbox: [ok: %{entry: %Entry{}}]}} =
             IMGateway.accept_message_event(event)
  end

  defp insert_delivery_rule!(name, match_expr \\ ~s(type == "bullx.message.received")) do
    agent_uid = ai_agent!("sink-#{name}")

    %DeliveryRule{}
    |> DeliveryRule.changeset(%{
      name: name,
      active: true,
      priority: 100,
      match_expr: match_expr,
      agent_uid: agent_uid,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp force_mailbox_entries_ready do
    Repo.update_all(Entry, set: [available_at: DateTime.utc_now(:microsecond)])
  end

  defp assert_entry_status(entry_id, expected_status, attempts \\ 20)

  defp assert_entry_status(entry_id, expected_status, attempts) when attempts > 0 do
    case Repo.get!(Entry, entry_id).status do
      ^expected_status ->
        :ok

      _status ->
        Process.sleep(25)
        assert_entry_status(entry_id, expected_status, attempts - 1)
    end
  end

  defp assert_entry_status(entry_id, expected_status, 0) do
    status = Repo.get!(Entry, entry_id).status
    flunk("expected mailbox entry #{entry_id} to be #{expected_status}, got: #{status}")
  end

  defp insert_agent_delivery_rule!(
         agent_uid,
         match_expr \\ ~s(type == "bullx.message.received")
       ) do
    %DeliveryRule{}
    |> DeliveryRule.changeset(%{
      name: "im route #{agent_uid} #{BullX.Ext.generic_hash(match_expr)}",
      active: true,
      priority: 100,
      match_expr: match_expr,
      agent_uid: agent_uid,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp ai_agent!(uid) do
    {:ok, %{principal: principal}} =
      BullX.Principals.create_agent(%{
        principal: %{uid: "imgateway-agent-#{uid}", display_name: "IMGateway Agent #{uid}"},
        agent: %{
          profile: %{
            "ai_agent" => %{
              "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
              "mission" => "Handle IMGateway tests."
            }
          }
        }
      })

    principal.uid
  end

  defp im_message_event(
         id,
         message_id,
         text,
         trusted_realm_by_default \\ true,
         routing_facts \\ %{"attention_reason" => "dm", "group_message_mode" => "addressed_only"}
       ) do
    %{
      "id" => id,
      "source" => "feishu://main/tenant",
      "type" => "bullx.message.received",
      "time" => "2026-05-27T00:00:00Z",
      "data" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "channel" => %{
          "adapter" => "feishu",
          "id" => "main",
          "kind" => "group",
          "trusted_realm_by_default" => trusted_realm_by_default
        },
        "scope" => %{"id" => "chat_1", "thread_id" => nil},
        "actor" => %{
          "external_account_id" => "feishu:user_id:user_x",
          "user_id" => "user_x",
          "open_id" => "ou_user",
          "display_name" => "Alice",
          "principal" => nil
        },
        "refs" => [%{"kind" => "feishu.message", "id" => message_id}],
        "reply_address" => %{
          "adapter" => "feishu",
          "channel_id" => "main",
          "scope_id" => "chat_1",
          "reply_to_external_id" => message_id
        },
        "routing_facts" => Map.put(routing_facts, "chat_type", "group"),
        "raw_ref" => %{"message_id" => message_id, "tenant_key" => "tenant"}
      }
    }
  end

  defp warmup_mail(id) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "bullx://test/im-gateway",
      "type" => "bullx.message.received",
      "time" => "2026-05-27T00:00:00Z",
      "datacontenttype" => "application/json",
      "data" => %{
        "routing_facts" => %{
          "attention_reason" => "unaddressed",
          "group_message_mode" => "engage_all"
        }
      }
    }
  end
end
