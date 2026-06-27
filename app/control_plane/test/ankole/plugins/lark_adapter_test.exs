defmodule Ankole.Plugins.LarkAdapterTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Actors.ActorInput
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins.LarkAdapter.ConnectionOwner
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.Outbox
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry
  alias FeishuOpenAPI.Error
  alias FeishuOpenAPI.Event

  import Ankole.PrincipalsFixtures

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @base_ms DateTime.to_unix(@base_time, :millisecond)

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())
  end

  describe "plugin declaration" do
    test "declares the stable Lark adapter contracts and encrypted config patterns" do
      assert LarkAdapter.plugin_id() == "lark-adapter"
      assert LarkAdapter.display_name() == "Lark / Feishu"

      assert [
               %{contract_id: "signals_gateway.adapter", id: "lark"},
               %{contract_id: "principals.identity_provider", id: "lark"}
             ] = LarkAdapter.adapter_declarations()

      patterns = LarkAdapter.app_config_patterns()

      assert Enum.map(patterns, & &1.id) == [
               "signals_gateway.lark.bindings.*",
               "principals.identity_providers.lark.*"
             ]

      assert Enum.all?(patterns, & &1.encrypted)
    end

    test "chat and identity config validation applies design defaults" do
      assert {:ok, chat} =
               Config.validate_chat_config(%{
                 "appId" => "cli_x",
                 "appSecret" => "secret"
               })

      assert chat["domain"] == "feishu"
      assert chat["group_message_mode"] == "observe_all"
      assert chat["platformSubjectNamespace"] == "lark-main"
      assert chat["streamingEnabled"] == true

      assert {:ok, identity} =
               Config.validate_identity_config(%{
                 "appId" => "cli_x",
                 "appSecret" => "secret"
               })

      assert identity["oidc"]["enabled"] == true
      assert identity["sync"]["pageSize"] == 50

      assert {:error, {:invalid_integer_range, "pageSize", 1, 50}} =
               Config.validate_identity_config(%{
                 "appId" => "cli_x",
                 "appSecret" => "secret",
                 "sync" => %{"pageSize" => 100}
               })
    end
  end

  describe "connection ownership" do
    test "reconciler starts enabled chat bindings through the connection supervisor" do
      registry = unique_module("LarkConnectionRegistry")
      supervisor = unique_module("LarkConnectionSupervisor")

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()

      assert {:ok, _} =
               AppConfigure.put_global_by_key(
                 Config.chat_config_key("lark-first"),
                 %{
                   "appId" => "cli_reconciler",
                   "appSecret" => "secret",
                   "platformSubjectNamespace" => "lark-main",
                   "userName" => "Lark Bot"
                 }
               )

      assert {:ok, _} =
               AppConfigure.put_global_by_key(
                 Config.chat_config_key("lark-second"),
                 %{
                   "appId" => "cli_reconciler",
                   "appSecret" => "secret",
                   "platformSubjectNamespace" => "lark-main",
                   "userName" => "Lark Bot"
                 }
               )

      binding_fixture(first_agent.uid, "lark-first", :ignore)
      binding_fixture(second_agent.uid, "lark-second", :may_intervene)

      assert %{started: 1, errors: []} =
               ConnectionReconciler.reconcile_once(
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert [{"feishu", "cli_reconciler"}] =
               ConnectionSupervisor.registered_keys(registry: registry)
    end

    test "reconciler starts enabled identity provider consumers" do
      registry = unique_module("LarkIdentityConnectionRegistry")
      supervisor = unique_module("LarkIdentityConnectionSupervisor")

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-main",
                 "lark",
                 %{"appId" => "cli_identity_reconciler", "appSecret" => "secret"},
                 true
               )

      assert %{started: 1, errors: []} =
               ConnectionReconciler.reconcile_once(
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert [{pid, _value}] = Registry.lookup(registry, {"feishu", "cli_identity_reconciler"})

      assert %{
               consumer_count: 1,
               consumer_kinds: [:identity_provider]
             } = ConnectionOwner.status(pid)
    end

    test "keeps one owner per domain and app id and rejects secret conflicts" do
      registry = unique_module("LarkConnectionRegistry")
      supervisor = unique_module("LarkConnectionSupervisor")

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

      config = chat_config()
      context = adapter_context(agent_fixture().principal.uid)
      consumer = Inbound.chat_consumer(context, config)

      assert {:ok, first_pid} =
               ConnectionSupervisor.ensure_started(config, [consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert {:ok, ^first_pid} =
               ConnectionSupervisor.ensure_started(config, [consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert {:error, :conflicting_app_secret} =
               ConnectionSupervisor.ensure_started(
                 %{config | "appSecret" => "different"},
                 [consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      changed_consumer =
        Inbound.chat_consumer(
          AdapterContext.new(
            agent_uid: context.agent_uid,
            binding_name: "other-lark",
            adapter: "lark",
            user_name: "Bot"
          ),
          config
        )

      assert {:ok, restarted_pid} =
               ConnectionSupervisor.ensure_started(config, [changed_consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert restarted_pid != first_pid
    end
  end

  describe "inbound chat events" do
    test "message receive observes platform subject then emits a typed gateway input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      assert {:ok, [%{status: :accepted, actor_input: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", receive_event(), [consumer])

      assert input.type == "command.steer"
      assert input.signal_channel_id == "lark:oc_group"
      assert input.provider_thread_id == "lark:oc_group:om_1"

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:oc_group",
               provider_entry_id: "om_1"
             ).text ==
               "@_user_1 /steer ship it"

      assert Repo.aggregate(ActorInput, :count) == 1

      assert {:ok, observed} =
               Ankole.Principals.resolve_platform_subject("lark-main", "ou_alice")

      assert observed.uid == "ou_alice"
    end

    test "message receive strips provider mention placeholders before command detection" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_retry",
              "content" => ~s({"text":"@_user_1 /retry １２"}),
              "mentions" => [
                %{"key" => "_user_1", "name" => "Lark Bot", "id" => %{"open_id" => "ou_bot"}}
              ]
          }
        end)

      assert {:ok, [%{status: :accepted, actor_input: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert input.type == "command.retry"
      assert input.payload["data"]["command"]["argsText"] == "12"
    end

    test "bot and app senders are ignored before they can echo into actor input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_sender(fn _sender ->
          %{
            "sender_type" => "bot",
            "sender_name" => "Lark Bot",
            "sender_id" => %{"open_id" => "ou_bot"}
          }
        end)

      assert {:ok, [%{status: :ignored_provider_self_sender, reason: :provider_self_sender}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(SignalEntry, :count) == 0
    end

    test "empty and unsupported non-text messages are explicitly ignored" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      empty_text =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_empty",
              "content" => ~s({"text":"   "}),
              "mentions" => []
          }
        end)

      unsupported_with_title =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_share",
              "message_type" => "share_chat",
              "content" => ~s({"title":"do not guess from title"}),
              "mentions" => []
          }
        end)

      assert {:ok, [%{status: :ignored_empty_or_unsupported_message}]} =
               Inbound.handle_message_receive("im.message.receive_v1", empty_text, [consumer])

      assert {:ok, [%{status: :ignored_empty_or_unsupported_message}]} =
               Inbound.handle_message_receive("im.message.receive_v1", unsupported_with_title, [
                 consumer
               ])

      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(SignalEntry, :count) == 0
    end

    test "non-text materialized provider resources enter as attachment-only facts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :record_only)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_file",
              "message_type" => "file",
              "content" => ~s({"file_key":"file_1","file_name":"deck.pdf"}),
              "mentions" => []
          }
        end)

      assert {:ok, [%{status: :recorded, signal_entry: entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert entry.text == nil

      assert [
               %{
                 "provider_ref" => "lark:file:file_1",
                 "provider" => "lark",
                 "source_message_id" => "om_file",
                 "file_key" => "file_1",
                 "download_type" => "file",
                 "resource_type" => "file",
                 "name" => "deck.pdf"
               }
             ] = entry.attachments

      assert Repo.aggregate(ActorInput, :count) == 0
    end

    test "enabled materializer adds worker file paths to provider attachments" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :record_only)

      materializer = fn attachments, _message, _consumer ->
        {:ok,
         Enum.map(attachments, fn attachment ->
           attachment
           |> Map.put("agent_computer_path", "/workspace/user-files/inbox/lark/om_file/deck.pdf")
           |> Map.put("user_files_relative_path", "inbox/lark/om_file/deck.pdf")
           |> Map.put("xxh3_128", "8db84f6b892cfa6bdad930c907ecb808")
         end)}
      end

      consumer =
        Inbound.chat_consumer(adapter_context(agent.uid), chat_config(),
          materialize_attachments: true,
          attachment_materializer: materializer
        )

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_file",
              "message_type" => "file",
              "content" => ~s({"file_key":"file_1","file_name":"deck.pdf"}),
              "mentions" => []
          }
        end)

      assert {:ok, [%{status: :recorded, signal_entry: entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert [
               %{
                 "provider_ref" => "lark:file:file_1",
                 "agent_computer_path" => "/workspace/user-files/inbox/lark/om_file/deck.pdf",
                 "user_files_relative_path" => "inbox/lark/om_file/deck.pdf",
                 "xxh3_128" => "8db84f6b892cfa6bdad930c907ecb808"
               }
             ] = entry.attachments
    end

    test "user senders without provider-scoped user_id fail closed" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_sender(fn sender ->
          put_in(sender, ["sender_id"], Map.delete(sender["sender_id"], "user_id"))
        end)

      assert {:error, :missing_platform_subject} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(SignalEntry, :count) == 0
    end

    test "reaction and recall events update the provider mirror through gateway APIs" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("im.message.receive_v1", receive_event(), [consumer])

      assert {:ok, [%{status: :mirrored, signal_entry: reacted}]} =
               Inbound.handle_reaction_created(
                 "im.message.reaction.created_v1",
                 reaction_event(),
                 [
                   consumer
                 ]
               )

      assert reacted.reactions["thumbs_up"] == ["ou_alice"]
      assert reacted.raw_reaction_keys["thumbs_up"] == "THUMBSUP"

      assert {:ok, [%{deleted_mirror_entries: 1}]} =
               Inbound.handle_message_removed("im.message.recalled_v1", recall_event(), [
                 consumer
               ])

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:oc_group",
               provider_entry_id: "om_1"
             )
    end

    test "card action emits action input instead of fake text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      assert {:ok, [%{status: :accepted, actor_input: input}]} =
               Inbound.handle_card_action("card.action.trigger", card_action_event(), [consumer])

      assert input.type == "signal.action.invoked"
      assert input.payload["data"]["action"]["value"]["selectedOptionId"] == "approve"
    end
  end

  describe "outbox request mapping" do
    test "builds text, reply, card, reaction, and delete requests from gateway rows" do
      assert {:ok, post} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :post,
                 signal_channel_id: "lark:oc_group",
                 fallback_visible_text: "hello",
                 idempotency_key: "uuid-1"
               })

      assert post.path == "im/v1/messages"
      assert post.query == [receive_id_type: "chat_id"]
      assert post.body.receive_id == "oc_group"
      assert post.body.uuid == "uuid-1"

      assert {:ok, reply} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :reply,
                 signal_channel_id: "lark:oc_group",
                 source_provider_entry_id: "om_1",
                 fallback_visible_text: "anchored"
               })

      assert reply.path == "im/v1/messages/:message_id/reply"
      assert reply.path_params == %{message_id: "om_1"}
      refute Map.has_key?(reply.body, :receive_id)

      assert {:ok, file_reply} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :reply,
                 signal_channel_id: "lark:oc_group",
                 source_provider_entry_id: "om_1",
                 payload: %{
                   "attachments" => [
                     %{"provider_file_key" => "file_uploaded_1", "name" => "report.txt"}
                   ]
                 },
                 fallback_visible_text: "report attached"
               })

      assert file_reply.body.msg_type == "file"
      assert {:ok, file_content} = Ankole.JSON.decode(file_reply.body.content)
      assert file_content == %{"file_key" => "file_uploaded_1"}

      assert {:ok, edit} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :edit,
                 target_provider_entry_id: "om_1",
                 fallback_visible_text: "edited"
               })

      assert edit.method == :put
      assert edit.path == "im/v1/messages/:message_id"
      assert edit.path_params == %{message_id: "om_1"}
      assert edit.body == %{msg_type: "text", content: ~s({"text":"edited"})}

      assert {:ok, card} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :card,
                 signal_channel_id: "lark:oc_group",
                 payload: %{"card" => %{"schema" => "2.0", "body" => %{"elements" => []}}},
                 fallback_visible_text: "card fallback"
               })

      assert card.body.msg_type == "interactive"

      assert {:ok, reaction} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :reaction_add,
                 target_provider_entry_id: "om_1",
                 payload: %{"reaction_key" => "thumbs_up"}
               })

      assert reaction.body == %{reaction_type: %{emoji_type: "THUMBSUP"}}

      assert {:ok, delete} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :delete,
                 target_provider_entry_id: "om_1"
               })

      assert delete.method == :delete
      assert delete.path_params == %{message_id: "om_1"}

      assert {:ok, divider} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :divider,
                 signal_channel_id: "lark:oc_group",
                 fallback_visible_text: "New Session",
                 payload: %{"i18n" => %{"zh_CN" => "新会话"}}
               })

      assert divider.body.msg_type == "system"
      assert {:ok, divider_content} = Ankole.JSON.decode(divider.body.content)
      assert divider_content["type"] == "divider"
      assert get_in(divider_content, ["params", "divider_text", "text"]) == "New Session"
      assert get_in(divider_content, ["params", "divider_text", "i18n_text", "zh_CN"]) == "新会话"
    end

    test "renders control and progress notices as compact updateable cards" do
      assert {:ok, control} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :card,
                 signal_channel_id: "lark:oc_group",
                 payload: %{"control_notice" => %{"text" => "Started a new conversation."}},
                 fallback_visible_text: "Started a new conversation."
               })

      assert control.body.msg_type == "interactive"
      assert {:ok, control_card} = Ankole.JSON.decode(control.body.content)
      assert control_card["schema"] == "2.0"
      assert get_in(control_card, ["config", "update_multi"]) == true
      assert get_in(control_card, ["body", "elements", Access.at(0), "tag"]) == "div"

      assert {:ok, progress} =
               Outbox.request_for_outbox(%OutboxEntry{
                 operation: :card,
                 signal_channel_id: "lark:oc_group",
                 payload: %{
                   "progress_notice" => %{
                     "text" => "以上历史对话记录已被压缩",
                     "show_divider" => true
                   }
                 },
                 fallback_visible_text: "以上历史对话记录已被压缩"
               })

      assert progress.body.msg_type == "interactive"
      assert {:ok, progress_card} = Ankole.JSON.decode(progress.body.content)
      assert get_in(progress_card, ["body", "elements", Access.at(0), "tag"]) == "hr"

      assert get_in(progress_card, ["body", "elements", Access.at(1), "text", "content"]) ==
               "以上历史对话记录已被压缩"
    end

    test "reply fallback recognizes Lark target-gone provider codes" do
      assert Outbox.target_gone_error?(%Error{code: 23_006, msg: "message not exist"})
      assert Outbox.target_gone_error?(%Error{code: 23_002, msg: "message withdrawn"})
      refute Outbox.target_gone_error?(%Error{code: 99_999, msg: "rate limited"})
    end
  end

  describe "identity provider" do
    test "authorization URL and directory upsert converge on platform subject" do
      config = identity_config()

      assert {:ok, url} =
               IdentityProvider.authorization_url(config,
                 redirect_uri: "https://ankole.example/auth/lark/callback",
                 state: "state-1"
               )

      assert url =~ "https://open.feishu.cn/open-apis/authen/v1/authorize?"
      assert url =~ "app_id=cli_test"

      assert {:ok, observed} =
               IdentityProvider.upsert_user("lark-main", %{
                 "user_id" => "ou_bob",
                 "name" => "Bob",
                 "enterprise_email" => "bob@example.com",
                 "mobile" => "13800000000",
                 "open_id" => "ou_open_bob",
                 "department_ids" => ["od_1"]
               })

      assert observed.principal.uid == "ou_bob"
      assert observed.human_user.email == "bob@example.com"
      assert observed.human_user.mobile == "+8613800000000"
      assert observed.identity.provider == "lark-main"
      assert observed.identity.external_id == "ou_bob"
      assert observed.identity.metadata["open_id"] == "ou_open_bob"
    end

    test "directory upsert never falls back to open_id as platform subject" do
      assert {:error, :missing_user_id} =
               IdentityProvider.upsert_user("lark-main", %{
                 "open_id" => "ou_open_only",
                 "union_id" => "on_union"
               })
    end

    test "contact events enqueue full sync when incremental identity is incomplete" do
      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-main",
                 "lark",
                 %{"appId" => "cli_identity", "appSecret" => "secret"},
                 true
               )

      event = %Event{
        id: "evt_contact",
        type: "contact.user.updated_v3",
        tenant_key: "tenant-a",
        app_id: "cli_identity",
        created_at: @base_time,
        content: %{"user" => %{"open_id" => "ou_open_only"}},
        raw: %{}
      }

      assert {:ok, [%{status: :full_sync_enqueued, reason: :missing_user_id}]} =
               IdentityProvider.handle_contact_event("contact.user.updated_v3", event, [
                 IdentityProvider.identity_consumer("lark-main", identity_config())
               ])

      assert_enqueued(
        worker: SyncProvider,
        args: %{
          "provider_id" => "lark-main",
          "reason" => "missing_user_id",
          "source" => "lark_contact_event"
        }
      )
    end
  end

  defp binding_fixture(agent_uid, name, policy) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "lark",
        config_ref: "app-config://#{Config.chat_config_key(name)}",
        filters: %{},
        unaddressed_group_message_policy: policy
      })

    binding
  end

  defp adapter_context(agent_uid) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: "lark",
      adapter: "lark",
      user_name: "Lark Bot"
    )
  end

  defp chat_config do
    {:ok, config} =
      Config.validate_chat_config(%{
        "appId" => "cli_test",
        "appSecret" => "secret",
        "platformSubjectNamespace" => "lark-main"
      })

    config
  end

  defp identity_config do
    {:ok, config} =
      Config.validate_identity_config(%{
        "appId" => "cli_test",
        "appSecret" => "secret"
      })

    config
  end

  defp receive_event do
    %Event{
      id: "evt_receive",
      type: "im.message.receive_v1",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "sender" => %{
          "sender_type" => "user",
          "sender_name" => "Alice",
          "sender_id" => %{
            "user_id" => "ou_alice",
            "open_id" => "ou_open_alice",
            "union_id" => "onion_alice"
          }
        },
        "message" => %{
          "message_id" => "om_1",
          "chat_id" => "oc_group",
          "chat_type" => "group",
          "message_type" => "text",
          "content" => ~s({"text":"@_user_1 /steer ship it"}),
          "mentions" => [
            %{"key" => "@_user_1", "name" => "Lark Bot", "id" => %{"open_id" => "ou_bot"}}
          ],
          "create_time" => Integer.to_string(@base_ms)
        }
      },
      raw: %{"schema" => "2.0"}
    }
  end

  defp update_message(%Event{content: content} = event, fun) when is_function(fun, 1) do
    %{event | content: Map.update!(content, "message", fun)}
  end

  defp update_sender(%Event{content: content} = event, fun) when is_function(fun, 1) do
    %{event | content: Map.update!(content, "sender", fun)}
  end

  defp reaction_event do
    %Event{
      id: "evt_reaction",
      type: "im.message.reaction.created_v1",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "operator" => %{"user_id" => "ou_alice"},
        "message" => %{"message_id" => "om_1", "chat_id" => "oc_group"},
        "reaction_type" => %{"emoji_type" => "THUMBSUP"}
      },
      raw: %{}
    }
  end

  defp recall_event do
    %Event{
      id: "evt_recall",
      type: "im.message.recalled_v1",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "message_id" => "om_1",
        "chat_id" => "oc_group",
        "chat_type" => "group",
        "recall_time" => Integer.to_string(@base_ms)
      },
      raw: %{}
    }
  end

  defp card_action_event do
    %Event{
      id: "evt_card",
      type: "card.action.trigger",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "open_chat_id" => "oc_group",
        "open_message_id" => "om_1",
        "user_id" => "ou_alice",
        "action" => %{
          "name" => "approval",
          "value" => %{
            "selectedOptionId" => "approve"
          }
        }
      },
      raw: %{}
    }
  end

  defp unique_module(prefix) do
    Module.concat([__MODULE__, :"#{prefix}#{System.unique_integer([:positive])}"])
  end
end
