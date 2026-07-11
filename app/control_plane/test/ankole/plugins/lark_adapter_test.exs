defmodule Ankole.Plugins.LarkAdapterTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins.LarkAdapter.ConnectionOwner
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.IMGroups
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.Jobs.RefreshIMGroup
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry
  alias FeishuOpenAPI.Client
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.TokenStore

  import Ankole.PrincipalsFixtures
  import ExUnit.CaptureLog

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @base_ms DateTime.to_unix(@base_time, :millisecond)

  defmodule TestConnectionSupervisor do
    @moduledoc false

    def ensure_started(_config, _consumers, _opts), do: {:ok, self()}
  end

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())
  end

  describe "plugin declaration" do
    test "declares the stable Lark adapter contracts and encrypted config patterns" do
      assert LarkAdapter.plugin_id() == "lark-adapter"

      assert LarkAdapter.display_name() == %{
               "default" => "Lark Adapter",
               "zh-Hans-CN" => "飞书适配器"
             }

      refute function_exported?(LarkAdapter, :setup_metadata, 0)

      assert [
               %{
                 contract_id: "signals_gateway.adapter",
                 id: "lark",
                 config_key_pattern: "signals_gateway.lark.bindings.<id>",
                 fields: chat_fields,
                 supported_group_message_modes: [
                   "addressed_only",
                   "observe_all",
                   "may_intervene"
                 ]
               },
               %{
                 contract_id: "principals.identity_provider",
                 id: "lark",
                 config_key_pattern: "principals.identity_providers.lark.<id>",
                 capabilities: identity_capabilities,
                 fields: identity_fields
               }
             ] = LarkAdapter.adapter_declarations()

      assert identity_capabilities == [
               "oidc_authorization",
               "oidc_code_exchange",
               "directory_full_sync",
               "directory_realtime_sync"
             ]

      assert Enum.map(chat_fields, & &1.path) == [
               "appID",
               "appSecret",
               "domain",
               "baseURL",
               "platformSubjectNamespace",
               "userName"
             ]

      assert Enum.map(identity_fields, & &1.path) == [
               "appID",
               "appSecret",
               "domain",
               "oidc.enabled",
               "oidc.scopes",
               "sync.contacts",
               "sync.websocket",
               "sync.pageSize"
             ]

      assert hd(chat_fields).label["zh-Hans-CN"] == "应用 ID"
      assert hd(chat_fields).description["default"] == "Self-built app identifier."
      assert Enum.all?(chat_fields ++ identity_fields, &localized_field?/1)

      chat_fields_by_path = Map.new(chat_fields, &{&1.path, &1})
      identity_fields_by_path = Map.new(identity_fields, &{&1.path, &1})

      assert Enum.all?(chat_fields, &(&1.advanced == false))
      assert identity_fields_by_path["appID"].advanced == false
      assert identity_fields_by_path["oidc.scopes"].advanced == true
      assert identity_fields_by_path["sync.websocket"].advanced == true
      assert identity_fields_by_path["sync.pageSize"].advanced == true
      assert chat_fields_by_path["appID"].advanced == false

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
                 "appID" => "cli_x",
                 "appSecret" => "secret"
               })

      assert chat["domain"] == "feishu"
      assert chat["baseURL"] == nil
      refute Map.has_key?(chat, "group_message_mode")
      assert chat["platformSubjectNamespace"] == "lark-main"
      assert chat["botOpenID"] == nil
      assert chat["botUserID"] == nil

      # A binding no longer requires a hand-entered bot identity: the bot's own
      # open_id is resolved from bot/v3/info at connection time.
      assert {:ok, %{"botOpenID" => nil, "botUserID" => nil}} =
               Config.validate_binding_config(%{
                 "appID" => "cli_x",
                 "appSecret" => "secret"
               })

      assert {:ok, %{"baseURL" => "http://127.0.0.1:4455"}} =
               Config.validate_chat_config(%{
                 "appID" => "cli_x",
                 "appSecret" => "secret",
                 "baseURL" => "http://127.0.0.1:4455"
               })

      assert {:error, {:invalid_base_url, "baseURL"}} =
               Config.validate_chat_config(%{
                 "appID" => "cli_x",
                 "appSecret" => "secret",
                 "baseURL" => "ftp://bad"
               })

      # With no botOpenID configured, the adapter resolves the bot's own open_id
      # from bot/v3/info using the app credentials alone.
      resolved =
        Config.resolve_runtime_bot_identity(
          chat,
          bot_info_fetcher: fn config ->
            send(self(), {:bot_info_config, Map.take(config, ["appID", "botOpenID"])})
            {:ok, "ou_runtime_bot"}
          end
        )

      assert_received {:bot_info_config, %{"appID" => "cli_x", "botOpenID" => nil}}
      assert resolved["botOpenID"] == nil
      assert resolved["runtimeBotOpenID"] == "ou_runtime_bot"

      # An explicit botOpenID override skips the provider lookup entirely.
      assert Config.resolve_runtime_bot_identity(
               %{chat | "botOpenID" => "ou_explicit"},
               bot_info_fetcher: fn _config -> {:error, :should_not_be_called} end
             ) == %{chat | "botOpenID" => "ou_explicit"}

      assert {:ok, identity} =
               Config.validate_identity_config(%{
                 "appID" => "cli_x",
                 "appSecret" => "secret"
               })

      assert identity["oidc"]["enabled"] == true
      assert identity["sync"]["contacts"] == true
      assert identity["sync"]["pageSize"] == 50

      assert {:ok, identity_sync_disabled} =
               Config.validate_identity_config(%{
                 "appID" => "cli_x",
                 "appSecret" => "secret",
                 "sync" => %{"contacts" => false, "websocket" => true}
               })

      assert identity_sync_disabled["sync"]["contacts"] == false
      assert identity_sync_disabled["sync"]["websocket"] == false
      refute Map.has_key?(identity_sync_disabled["sync"], "users")
      refute Map.has_key?(identity_sync_disabled["sync"], "departments")

      assert {:error, {:invalid_integer_range, "pageSize", 1, 50}} =
               Config.validate_identity_config(%{
                 "appID" => "cli_x",
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
                   "appID" => "cli_reconciler",
                   "appSecret" => "secret",
                   "platformSubjectNamespace" => "lark-main",
                   "userName" => "Lark Bot"
                 }
               )

      assert {:ok, _} =
               AppConfigure.put_global_by_key(
                 Config.chat_config_key("lark-second"),
                 %{
                   "appID" => "cli_reconciler",
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
                 start_client?: false,
                 bot_info_fetcher: fn _config -> {:ok, "ou_runtime_bot"} end
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
                 %{"appID" => "cli_identity_reconciler", "appSecret" => "secret"},
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

    test "reconciler skips identity realtime consumer when directory sync is disabled" do
      registry = unique_module("LarkIdentityDisabledConnectionRegistry")
      supervisor = unique_module("LarkIdentityDisabledConnectionSupervisor")

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-disabled",
                 "lark",
                 %{
                   "appID" => "cli_identity_disabled",
                   "appSecret" => "secret",
                   "sync" => %{"contacts" => false, "websocket" => true}
                 },
                 true
               )

      assert %{started: 0, errors: []} =
               ConnectionReconciler.reconcile_once(
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert [] == Registry.lookup(registry, {"feishu", "cli_identity_disabled"})
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

    test "connection owner format_status omits client, dispatcher, and secrets" do
      state = %ConnectionOwner{
        key: {"feishu", "cli_status"},
        secret_fingerprint: String.duplicate("a", 64),
        consumer_fingerprint: String.duplicate("b", 64),
        consumer_count: 2,
        consumer_kinds: [:chat, :identity_provider],
        client: %{app_secret: "secret"},
        dispatcher: %{secret: "secret"},
        ws_pid: self(),
        ws_client_module: FeishuOpenAPI.WS.Client,
        start_client?: true
      }

      assert %{state: formatted_state} = ConnectionOwner.format_status(%{state: state})

      assert formatted_state == %{
               key: {"feishu", "cli_status"},
               secret_fingerprint: "aaaaaaaa",
               consumer_count: 2,
               consumer_kinds: [:chat, :identity_provider],
               ws_pid: self(),
               ws_client_module: FeishuOpenAPI.WS.Client,
               start_client?: true
             }

      refute Map.has_key?(formatted_state, :client)
      refute Map.has_key?(formatted_state, :dispatcher)
      refute inspect(formatted_state) =~ "app_secret"
      refute inspect(formatted_state) =~ "dispatcher"
      refute inspect(formatted_state) =~ String.duplicate("a", 64)
    end
  end

  describe "inbound chat events" do
    test "message receive observes platform subject then emits a typed gateway input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", receive_event(), [consumer])

      assert input.type == "command.steer"
      assert input.signal_channel_id == "lark:oc_group"
      assert input.provider_thread_id == "lark:oc_group:om_1"

      assert Repo.get_by!(Entry,
               signal_channel_id: "lark:oc_group",
               source_entry_id: "om_1"
             ).text ==
               "/steer ship it"

      assert Repo.aggregate(ActorEvent, :count) == 1

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
                %{"key" => "@_user_1", "name" => "Lark Bot", "id" => %{"open_id" => "ou_bot"}}
              ]
          }
        end)

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert input.type == "command.retry"
      assert input.payload["data"]["command"]["argsText"] == "12"
    end

    test "message receive strips the longest matching mention placeholder first" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_long_mention_key",
              "content" => ~s({"text":"@_user_10 /retry"}),
              "mentions" => [
                %{"key" => "@_user_1", "name" => "Other Bot", "id" => %{"open_id" => "ou_other"}},
                %{"key" => "@_user_10", "name" => "Lark Bot", "id" => %{"open_id" => "ou_bot"}}
              ]
          }
        end)

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert input.type == "command.retry"
    end

    test "bot and app senders are ignored before they can echo into actor event" do
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

      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
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
              "message_type" => "unknown_rich_type",
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

      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "rich Lark message types normalize to deterministic text without guessing sticker pixels" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :record_only)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      sticker =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_sticker",
              "message_type" => "sticker",
              "content" => ~s({"file_key":"sticker_1"}),
              "mentions" => []
          }
        end)

      location =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_location",
              "message_type" => "location",
              "content" => ~s({"name":"Office","latitude":31.2,"longitude":121.5}),
              "mentions" => []
          }
        end)

      share_chat =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_share_chat",
              "message_type" => "share_chat",
              "content" => ~s({"chat_id":"oc_shared","title":"Ops"}),
              "mentions" => []
          }
        end)

      share_user =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_share_user",
              "message_type" => "share_user",
              "content" => ~s({"user_id":"ou_shared","name":"Bob"}),
              "mentions" => []
          }
        end)

      assert {:ok, [%{status: :recorded, signal_entry: sticker_entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", sticker, [consumer])

      assert sticker_entry.text == "<|sticker|>"
      assert sticker_entry.attachments == []

      assert {:ok, [%{status: :recorded, signal_entry: location_entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", location, [consumer])

      assert location_entry.text == "<|location|> name=Office latitude=31.2 longitude=121.5"
      assert location_entry.attachments == []

      assert {:ok, [%{status: :recorded, signal_entry: share_chat_entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", share_chat, [consumer])

      assert share_chat_entry.text == "<|share_chat|> chat_id=oc_shared title=Ops"
      assert share_chat_entry.attachments == []

      assert {:ok, [%{status: :recorded, signal_entry: share_user_entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", share_user, [consumer])

      assert share_user_entry.text == "<|share_user|> user_id=ou_shared name=Bob"
      assert share_user_entry.attachments == []
    end

    test "post embedded images become normal image attachments" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :record_only)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_post_image",
              "message_type" => "post",
              "content" =>
                ~s({"content":[[{"tag":"text","text":"Look "},{"tag":"img","image_key":"img_1"},{"tag":"text","text":" here"}]]}),
              "mentions" => []
          }
        end)

      assert {:ok, [%{status: :recorded, signal_entry: entry}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert entry.text == "Look [image] here"

      assert [
               %{
                 "provider_ref" => "lark:image:img_1",
                 "provider" => "lark",
                 "source_message_id" => "om_post_image",
                 "file_key" => "img_1",
                 "download_type" => "image",
                 "resource_type" => "image"
               }
             ] = entry.attachments
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

      assert Repo.aggregate(ActorEvent, :count) == 0
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

    test "user senders without provider-scoped user_id are ignored with warning" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      event =
        receive_event()
        |> update_sender(fn sender ->
          put_in(sender, ["sender_id"], Map.delete(sender["sender_id"], "user_id"))
        end)

      log =
        capture_log([level: :warning], fn ->
          assert {:ok,
                  [
                    %{
                      status: :ignored_missing_platform_subject,
                      reason: :missing_platform_subject
                    }
                  ]} = Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])
        end)

      assert log =~ "lark adapter ignored message sender without user_id"

      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
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

      refute Repo.get_by(Entry,
               signal_channel_id: "lark:oc_group",
               source_entry_id: "om_1"
             )
    end

    test "card action emits action input instead of fake text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               Inbound.handle_card_action("card.action.trigger", card_action_event(), [consumer])

      assert input.type == "signal.action.invoked"
      assert input.payload["data"]["action"]["value"]["selectedOptionId"] == "approve"
    end
  end

  describe "IM group sync" do
    test "ensure merges participant map for multiple bindings in the same chat" do
      %{principal: first_agent} = agent_fixture(%{uid: unique_uid("lark-im-agent-a")})
      %{principal: second_agent} = agent_fixture(%{uid: unique_uid("lark-im-agent-b")})

      assert {:ok, first_group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_merge",
                 im_chat_attrs("oc_merge", "Ops Room", "cli_a"),
                 im_participant(first_agent.uid, "lark-a", "cli_a", "joined")
               )

      assert {:ok, second_group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_merge",
                 im_chat_attrs("oc_merge", "Ops Room Renamed", "cli_b"),
                 im_participant(second_agent.uid, "lark-b", "cli_b", "joined")
               )

      assert second_group.id == first_group.id

      group = Repo.get!(Group, first_group.id)
      participants = get_in(group.metadata, ["lark_im", "sync_participants"])

      assert participants["#{first_agent.uid}|lark-a"]["state"] == "joined"
      assert participants["#{second_agent.uid}|lark-b"]["state"] == "joined"
      assert group.display_name == "Ops Room Renamed"
      group_id = group.id

      assert %Channel{principal_group_id: ^group_id, name: "Ops Room Renamed"} =
               Repo.get(Channel, Inbound.signal_channel_id("oc_merge"))
    end

    test "all-left cleanup clears memberships but keeps group binding channel and grants" do
      %{principal: first_agent} = agent_fixture(%{uid: unique_uid("lark-left-agent-a")})
      %{principal: second_agent} = agent_fixture(%{uid: unique_uid("lark-left-agent-b")})
      %{principal: member} = human_fixture(%{uid: unique_uid("lark-left-member")})

      assert {:ok, first_group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_left",
                 im_chat_attrs("oc_left", "Left Room", "cli_a"),
                 im_participant(first_agent.uid, "lark-a", "cli_a", "joined")
               )

      assert {:ok, group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_left",
                 im_chat_attrs("oc_left", "Left Room", "cli_b"),
                 im_participant(second_agent.uid, "lark-b", "cli_b", "joined")
               )

      assert group.id == first_group.id

      assert {:ok, _membership} = AuthZ.add_principal_to_group(member.uid, group.id)

      assert {:ok, grant} =
               AuthZ.upsert_permission_grant(%{
                 group_id: group.id,
                 resource_pattern: "workspace:**",
                 action: "read"
               })

      assert {:ok, [%{status: :participant_marked_left}]} =
               IMGroups.handle_im_event(
                 "im.chat.member.bot.deleted_v1",
                 im_chat_event("oc_left"),
                 [
                   im_consumer(first_agent.uid, "lark-a", "cli_a")
                 ]
               )

      assert Repo.get_by(Membership, group_id: group.id, principal_uid: member.uid)

      assert {:ok, [%{status: :all_left_members_cleared, group_id: group_id}]} =
               IMGroups.handle_im_event(
                 "im.chat.member.bot.deleted_v1",
                 im_chat_event("oc_left"),
                 [
                   im_consumer(second_agent.uid, "lark-b", "cli_b")
                 ]
               )

      assert group_id == group.id
      assert Repo.get(Group, group.id)
      assert Repo.get(Grant, grant.id)

      assert Repo.get_by(ExternalBinding,
               provider: "lark-main",
               external_kind: :im_group,
               external_id: "oc_left"
             )

      assert %Channel{principal_group_id: ^group_id} =
               Repo.get(Channel, Inbound.signal_channel_id("oc_left"))

      refute Repo.get_by(Membership, group_id: group.id, principal_uid: member.uid)
    end

    test "chat disband marks all known participants left and clears memberships" do
      %{principal: first_agent} = agent_fixture(%{uid: unique_uid("lark-disband-agent-a")})
      %{principal: second_agent} = agent_fixture(%{uid: unique_uid("lark-disband-agent-b")})
      %{principal: member} = human_fixture(%{uid: unique_uid("lark-disband-member")})

      assert {:ok, first_group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_disband",
                 im_chat_attrs("oc_disband", "Disband Room", "cli_a"),
                 im_participant(first_agent.uid, "lark-a", "cli_a", "joined")
               )

      assert {:ok, group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_disband",
                 im_chat_attrs("oc_disband", "Disband Room", "cli_b"),
                 im_participant(second_agent.uid, "lark-b", "cli_b", "joined")
               )

      assert group.id == first_group.id

      assert {:ok, _membership} = AuthZ.add_principal_to_group(member.uid, group.id)

      assert {:ok, [%{status: :all_left_members_cleared}]} =
               IMGroups.handle_im_event("im.chat.disbanded_v1", im_chat_event("oc_disband"), [
                 im_consumer(first_agent.uid, "lark-a", "cli_a")
               ])

      group = Repo.get!(Group, group.id)
      participants = get_in(group.metadata, ["lark_im", "sync_participants"])

      assert participants["#{first_agent.uid}|lark-a"]["state"] == "left"
      assert participants["#{second_agent.uid}|lark-b"]["state"] == "left"
      refute Repo.get_by(Membership, group_id: group.id, principal_uid: member.uid)
    end

    test "member added without user_id is ignored without principal or refresh" do
      %{principal: agent} = agent_fixture(%{uid: unique_uid("lark-add-missing-subject-agent")})

      assert {:ok, group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_add_missing_subject",
                 im_chat_attrs("oc_add_missing_subject", "Add Missing Subject Room", "cli_add"),
                 im_participant(agent.uid, "lark", "cli_add", "joined")
               )

      principal_count = Repo.aggregate(Principal, :count)

      log =
        capture_log([level: :warning], fn ->
          assert {:ok,
                  [
                    %{
                      status: :ignored_missing_platform_subject,
                      reason: :missing_platform_subject
                    }
                  ]} =
                   IMGroups.handle_im_event(
                     "im.chat.member.user.added_v1",
                     im_member_event_without_user_id(
                       "oc_add_missing_subject",
                       "im.chat.member.user.added_v1",
                       "ou_add_missing_subject"
                     ),
                     [im_consumer(agent.uid, "lark", "cli_add")]
                   )
        end)

      assert log =~ "lark adapter ignored IM group member event without user_id"
      assert Repo.aggregate(Principal, :count) == principal_count
      assert Repo.aggregate(from(m in Membership, where: m.group_id == ^group.id), :count) == 0

      refute_enqueued(
        worker: RefreshIMGroup,
        args: %{
          "agent_uid" => agent.uid,
          "binding_name" => "lark",
          "chat_id" => "oc_add_missing_subject",
          "reason" => "member_added_missing_user_id"
        }
      )
    end

    test "member removed resolves platform subject identity instead of guessing principal uid" do
      %{principal: agent} = agent_fixture(%{uid: unique_uid("lark-remove-agent")})

      assert {:ok, observed} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_remove_external",
                 uid: unique_uid("lark-remove-principal"),
                 display_name: "Remove Me"
               })

      assert observed.principal.uid != "ou_remove_external"

      assert {:ok, group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_remove",
                 im_chat_attrs("oc_remove", "Remove Room", "cli_remove"),
                 im_participant(agent.uid, "lark", "cli_remove", "joined")
               )

      assert {:ok, _membership} = AuthZ.add_principal_to_group(observed.principal.uid, group.id)

      assert {:ok,
              [
                %{
                  status: :member_removed,
                  principal_uid: principal_uid,
                  group_id: group_id
                }
              ]} =
               IMGroups.handle_im_event(
                 "im.chat.member.user.deleted_v1",
                 im_member_event("oc_remove", "ou_remove_external"),
                 [im_consumer(agent.uid, "lark", "cli_remove")]
               )

      assert principal_uid == observed.principal.uid
      assert group_id == group.id
      refute Repo.get_by(Membership, group_id: group.id, principal_uid: observed.principal.uid)
    end

    test "member removed without user_id is ignored without open_id fallback or refresh" do
      %{principal: agent} =
        agent_fixture(%{uid: unique_uid("lark-remove-missing-subject-agent")})

      assert {:ok, observed} =
               Principals.upsert_platform_subject_human(%{
                 provider: "lark-main",
                 external_id: "ou_remove_missing_subject",
                 uid: unique_uid("lark-remove-missing-subject-principal"),
                 display_name: "External Remove"
               })

      assert {:ok, group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_remove_missing_subject",
                 im_chat_attrs(
                   "oc_remove_missing_subject",
                   "Remove Missing Subject Room",
                   "cli_remove"
                 ),
                 im_participant(agent.uid, "lark", "cli_remove", "joined")
               )

      assert {:ok, _membership} = AuthZ.add_principal_to_group(observed.principal.uid, group.id)

      log =
        capture_log([level: :warning], fn ->
          assert {:ok,
                  [
                    %{
                      status: :ignored_missing_platform_subject,
                      reason: :missing_platform_subject
                    }
                  ]} =
                   IMGroups.handle_im_event(
                     "im.chat.member.user.deleted_v1",
                     im_member_event_without_user_id(
                       "oc_remove_missing_subject",
                       "im.chat.member.user.deleted_v1",
                       "ou_remove_missing_subject"
                     ),
                     [im_consumer(agent.uid, "lark", "cli_remove")]
                   )
        end)

      assert log =~ "lark adapter ignored IM group member event without user_id"
      assert Repo.get_by(Membership, group_id: group.id, principal_uid: observed.principal.uid)

      refute_enqueued(
        worker: RefreshIMGroup,
        args: %{
          "agent_uid" => agent.uid,
          "binding_name" => "lark",
          "chat_id" => "oc_remove_missing_subject",
          "reason" => "member_removed_missing_user_id"
        }
      )
    end

    test "member removed with unknown platform subject enqueues refresh" do
      %{principal: agent} = agent_fixture(%{uid: unique_uid("lark-remove-missing-agent")})

      assert {:ok, _group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_remove_missing",
                 im_chat_attrs("oc_remove_missing", "Remove Missing Room", "cli_remove"),
                 im_participant(agent.uid, "lark", "cli_remove", "joined")
               )

      assert {:ok, [%{status: :refresh_enqueued}]} =
               IMGroups.handle_im_event(
                 "im.chat.member.user.deleted_v1",
                 im_member_event("oc_remove_missing", "ou_missing_remove"),
                 [im_consumer(agent.uid, "lark", "cli_remove")]
               )

      assert_enqueued(
        worker: RefreshIMGroup,
        args: %{
          "agent_uid" => agent.uid,
          "binding_name" => "lark",
          "chat_id" => "oc_remove_missing",
          "reason" => "member_removed_missing_identity"
        }
      )
    end

    test "namespace conflict does not flip existing channel group foreign key" do
      %{principal: first_agent} = agent_fixture(%{uid: unique_uid("lark-ns-agent-a")})
      %{principal: second_agent} = agent_fixture(%{uid: unique_uid("lark-ns-agent-b")})

      assert {:ok, first_group} =
               IMGroups.ensure_lark_im_group(
                 "lark-main",
                 "oc_namespace",
                 im_chat_attrs("oc_namespace", "Namespace Room", "cli_a"),
                 im_participant(first_agent.uid, "lark-a", "cli_a", "joined")
               )

      assert {:ok, second_group} =
               IMGroups.ensure_lark_im_group(
                 "other-lark",
                 "oc_namespace",
                 im_chat_attrs("oc_namespace", "Namespace Room", "cli_b"),
                 im_participant(second_agent.uid, "lark-b", "cli_b", "joined")
               )

      assert second_group.id != first_group.id

      assert %Channel{principal_group_id: group_id} =
               Repo.get(Channel, Inbound.signal_channel_id("oc_namespace"))

      assert group_id == first_group.id
    end

    test "message ingress with missing group FK only enqueues chat refresh" do
      %{principal: agent} = agent_fixture(%{uid: unique_uid("lark-ingress-refresh-agent")})
      channel_id = Inbound.signal_channel_id("oc_missing_fk")

      %Channel{}
      |> Channel.changeset(%{
        id: channel_id,
        kind: :im_group,
        reply_mode: :entry,
        name: "Missing FK",
        metadata: %{"chat_id" => "oc_missing_fk"},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })
      |> Repo.insert!()

      assert :ok =
               IMGroups.maybe_enqueue_missing_channel_refresh(
                 im_consumer(agent.uid, "lark", "cli_ingress"),
                 %{channel: %{kind: :im_group}, signal_channel_id: channel_id}
               )

      assert_enqueued(
        worker: RefreshIMGroup,
        args: %{
          "agent_uid" => agent.uid,
          "binding_name" => "lark",
          "chat_id" => "oc_missing_fk",
          "reason" => "missing_channel_principal_group"
        }
      )

      assert Repo.all(Group |> where([group], group.domain == :im_group)) == []
    end

    test "full sync skips disabled bindings without retryable error" do
      %{principal: agent} = agent_fixture(%{uid: unique_uid("lark-disabled-sync-agent")})

      assert {:ok, _} =
               AppConfigure.put_global_by_key(
                 Config.chat_config_key("lark-disabled-sync"),
                 chat_config(%{"appID" => "cli_disabled_sync"})
               )

      binding_fixture(agent.uid, "lark-disabled-sync", :ignore)
      assert {:ok, _binding} = SignalsGateway.disable_binding(agent.uid, "lark-disabled-sync")

      assert {:ok,
              %{
                status: :skipped_binding_disabled,
                binding: %{agent_uid: agent_uid, binding_name: "lark-disabled-sync"}
              }} = IMGroups.sync_binding(agent.uid, "lark-disabled-sync")

      assert agent_uid == agent.uid
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

    test "directory upsert syncs department memberships into marked external groups" do
      assert {:ok, managed_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_directory_#{System.unique_integer([:positive])}",
                 display_name: "Lark Directory",
                 domain: :directory
               })

      assert {:ok, unmarked_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_manual_#{System.unique_integer([:positive])}",
                 display_name: "Lark Manual"
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark-main",
                 external_kind: :directory_department,
                 external_id: "od_directory",
                 group_id: managed_group.id
               })

      Repo.insert!(%Ankole.AuthZ.ExternalBinding{
        provider: "lark-main",
        external_kind: :directory_department,
        external_id: "od_manual",
        group_id: unmarked_group.id,
        metadata: %{}
      })

      assert {:ok, observed} =
               IdentityProvider.upsert_user("lark-main", %{
                 "user_id" => "ou_directory_user",
                 "name" => "Directory User",
                 "department_ids" => ["od_directory", "od_manual"]
               })

      assert Repo.get_by(Membership,
               principal_uid: observed.principal.uid,
               group_id: managed_group.id
             )

      refute Repo.get_by(Membership,
               principal_uid: observed.principal.uid,
               group_id: unmarked_group.id
             )

      assert {:ok, _membership} =
               AuthZ.add_principal_to_group(observed.principal.uid, unmarked_group.id)

      assert {:ok, _observed} =
               IdentityProvider.upsert_user("lark-main", %{
                 "user_id" => "ou_directory_user",
                 "name" => "Directory User",
                 "department_ids" => []
               })

      refute Repo.get_by(Membership,
               principal_uid: observed.principal.uid,
               group_id: managed_group.id
             )

      assert Repo.get_by(Membership,
               principal_uid: observed.principal.uid,
               group_id: unmarked_group.id
             )
    end

    test "full directory sync reads users and departments through paginated contact API" do
      config = put_in(identity_config(), ["sync", "pageSize"], 17)
      client_opts = lark_http_client_opts()
      put_tenant_token(config, client_opts)
      on_exit(fn -> delete_tenant_token(config, client_opts) end)

      {:ok, requests} = Agent.start_link(fn -> [] end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(
          requests,
          &(&1 ++ [{conn.request_path, URI.decode_query(conn.query_string)}])
        )

        case conn.request_path do
          "/open-apis/contact/v3/departments/0/children" ->
            Req.Test.json(conn, %{
              "code" => 0,
              "data" => %{
                "items" => [
                  %{
                    "department_id" => "od_full_sync",
                    "parent_department_id" => "0",
                    "name" => "Full Sync Department"
                  }
                ],
                "has_more" => false
              }
            })

          "/open-apis/contact/v3/users" ->
            case URI.decode_query(conn.query_string) do
              %{"department_id" => "0"} ->
                Req.Test.json(conn, %{
                  "code" => 0,
                  "data" => %{
                    "items" => [
                      %{
                        "user_id" => "ou_full_sync_1",
                        "name" => "Full Sync One",
                        "department_ids" => []
                      },
                      %{"user_id" => "ou_full_sync_2", "name" => "Full Sync Two"}
                    ],
                    "has_more" => false
                  }
                })

              %{"department_id" => "od_full_sync"} ->
                Req.Test.json(conn, %{
                  "code" => 0,
                  "data" => %{
                    "items" => [
                      %{
                        "user_id" => "ou_full_sync_1",
                        "name" => "Full Sync One",
                        "department_ids" => ["od_full_sync"]
                      }
                    ],
                    "has_more" => false
                  }
                })

              _query ->
                Req.Test.json(conn, %{
                  "code" => 0,
                  "data" => %{"has_more" => false}
                })
            end
        end
      end)

      assert {:ok, %{users: 2, departments: 1}} =
               IdentityProvider.sync_directory("lark-main", config, client_opts: client_opts)

      assert {:ok, observed} =
               Ankole.Principals.resolve_platform_subject("lark-main", "ou_full_sync_1")

      assert observed.uid == "ou_full_sync_1"

      assert [department_group_id] =
               AuthZ.external_group_ids("lark-main", :directory_department, "od_full_sync")

      assert department_group = Repo.get(Group, department_group_id)
      assert department_group.name == "lark-main:department:od_full_sync"
      assert department_group.display_name == "Full Sync Department"
      assert department_group.domain == :directory

      assert get_in(department_group.metadata, [
               "external_directory",
               "parentExternalID"
             ]) == "0"

      assert Repo.get_by(Membership,
               principal_uid: observed.uid,
               group_id: department_group.id
             )

      assert Agent.get(requests, & &1) == [
               {"/open-apis/contact/v3/departments/0/children",
                %{
                  "department_id_type" => "department_id",
                  "fetch_child" => "true",
                  "page_size" => "17",
                  "user_id_type" => "user_id"
                }},
               {"/open-apis/contact/v3/users",
                %{
                  "department_id" => "0",
                  "department_id_type" => "department_id",
                  "page_size" => "17",
                  "user_id_type" => "user_id"
                }},
               {"/open-apis/contact/v3/users",
                %{
                  "department_id" => "od_full_sync",
                  "department_id_type" => "department_id",
                  "page_size" => "17",
                  "user_id_type" => "user_id"
                }}
             ]
    end

    test "identity websocket consumer starts only when realtime directory sync is enabled" do
      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-main",
                 "lark",
                 %{
                   "appID" => "cli_identity",
                   "appSecret" => "secret",
                   "sync" => %{"contacts" => true, "websocket" => false}
                 },
                 true
               )

      assert %{started: 0, errors: []} =
               ConnectionReconciler.reconcile_once(
                 connection_supervisor: TestConnectionSupervisor
               )

      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-main",
                 "lark",
                 %{
                   "appID" => "cli_identity",
                   "appSecret" => "secret",
                   "sync" => %{"contacts" => true, "websocket" => true}
                 },
                 true
               )

      assert %{started: 1, errors: []} =
               ConnectionReconciler.reconcile_once(
                 connection_supervisor: TestConnectionSupervisor
               )
    end

    test "directory upsert never falls back to open_id as platform subject" do
      assert {:error, :missing_user_id} =
               IdentityProvider.upsert_user("lark-main", %{
                 "open_id" => "ou_open_only",
                 "union_id" => "on_union"
               })
    end

    test "contact user events incrementally upsert platform subjects" do
      event = %Event{
        id: "evt_contact_user",
        type: "contact.user.updated_v3",
        tenant_key: "tenant-a",
        app_id: "cli_identity",
        created_at: @base_time,
        content: %{
          "user" => %{
            "user_id" => "ou_contact_incremental",
            "name" => "Contact Incremental",
            "enterprise_email" => "contact.incremental@example.com"
          }
        },
        raw: %{}
      }

      assert {:ok, [%{principal: principal, human_user: human_user}]} =
               IdentityProvider.handle_contact_event("contact.user.updated_v3", event, [
                 IdentityProvider.identity_consumer("lark-main", identity_config())
               ])

      assert principal.uid == "ou_contact_incremental"
      assert human_user.email == "contact.incremental@example.com"
    end

    test "contact events enqueue full sync when incremental identity is incomplete" do
      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-main",
                 "lark",
                 %{"appID" => "cli_identity", "appSecret" => "secret"},
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

    test "contact scope updates enqueue a full directory sync" do
      assert {:ok, _provider} =
               IdentityProviders.save_provider(
                 "lark-main",
                 "lark",
                 %{"appID" => "cli_identity", "appSecret" => "secret"},
                 true
               )

      event = %Event{
        id: "evt_contact_scope",
        type: "contact.scope.updated_v3",
        tenant_key: "tenant-a",
        app_id: "cli_identity",
        created_at: @base_time,
        content: %{},
        raw: %{}
      }

      assert {:ok, [%{status: :full_sync_enqueued, reason: :contact_scope_updated}]} =
               IdentityProvider.handle_contact_event("contact.scope.updated_v3", event, [
                 IdentityProvider.identity_consumer("lark-main", identity_config())
               ])

      assert_enqueued(
        worker: SyncProvider,
        args: %{
          "provider_id" => "lark-main",
          "reason" => "contact_scope_updated",
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

  defp im_consumer(agent_uid, binding_name, app_id) do
    %{
      kind: :chat,
      context:
        AdapterContext.new(
          agent_uid: agent_uid,
          binding_name: binding_name,
          adapter: "lark",
          user_name: "Lark Bot"
        ),
      config: chat_config(%{"appID" => app_id})
    }
  end

  defp im_chat_attrs(chat_id, name, app_id) do
    %{
      "name" => name,
      "app_id" => app_id,
      "domain" => "feishu",
      "raw_payload" => %{"chat_id" => chat_id, "name" => name}
    }
  end

  defp im_participant(agent_uid, binding_name, app_id, state) do
    %{
      "agent_uid" => agent_uid,
      "binding_name" => binding_name,
      "app_id" => app_id,
      "domain" => "feishu",
      "state" => state,
      "last_seen_at" => DateTime.to_iso8601(@base_time)
    }
  end

  defp im_chat_event(chat_id) do
    %Event{
      id: "evt_im_#{chat_id}",
      type: "im.chat.member.bot.deleted_v1",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{"chat" => %{"chat_id" => chat_id}},
      raw: %{}
    }
  end

  defp im_member_event(chat_id, user_id) do
    %Event{
      id: "evt_im_member_#{chat_id}_#{user_id}",
      type: "im.chat.member.user.deleted_v1",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "chat" => %{"chat_id" => chat_id},
        "member" => %{"member_id" => %{"user_id" => user_id}}
      },
      raw: %{}
    }
  end

  defp im_member_event_without_user_id(chat_id, event_type, open_id) do
    event_id_type = String.replace(event_type, ".", "_")

    %Event{
      id: "evt_im_member_missing_user_id_#{chat_id}_#{event_id_type}",
      type: event_type,
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "chat" => %{"chat_id" => chat_id},
        "member" => %{
          "member_type" => "user",
          "member_id" => %{"open_id" => open_id, "union_id" => "on_#{open_id}"},
          "name" => "External Member"
        }
      },
      raw: %{}
    }
  end

  defp chat_config(overrides \\ %{}) do
    {:ok, config} =
      %{
        "appID" => "cli_test",
        "appSecret" => "secret",
        "platformSubjectNamespace" => "lark-main",
        "botOpenID" => "ou_bot"
      }
      |> Map.merge(overrides)
      |> Config.validate_chat_config()

    config
  end

  defp identity_config do
    {:ok, config} =
      Config.validate_identity_config(%{
        "appID" => "cli_test",
        "appSecret" => "secret"
      })

    config
  end

  defp lark_http_client_opts do
    [req_options: [plug: {Req.Test, __MODULE__}]]
  end

  defp put_tenant_token(config, client_opts) do
    ensure_token_store()

    config
    |> Config.client(client_opts)
    |> tenant_key(nil)
    |> then(&:ets.insert(TokenStore.table(), {&1, "t-token", :infinity}))
  end

  defp delete_tenant_token(config, client_opts) do
    config
    |> Config.client(client_opts)
    |> tenant_key(nil)
    |> then(&:ets.delete(TokenStore.table(), &1))
  end

  defp tenant_key(%Client{} = client, tenant_key) do
    {:tenant, Client.cache_namespace(client), tenant_key}
  end

  defp ensure_token_store do
    if :ets.info(TokenStore.table()) == :undefined do
      :ets.new(TokenStore.table(), [:named_table, :public, :set, read_concurrency: true])
    end
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

  defp localized_field?(field) do
    localized_text?(field.label) and localized_text?(field.description) and
      Enum.all?(Map.get(field, :options, []), &localized_text?(&1.label))
  end

  defp localized_text?(%{"default" => default} = value) when is_binary(default) do
    Enum.all?(value, fn {locale, text} -> is_binary(locale) and is_binary(text) end)
  end

  defp localized_text?(_value), do: false
end
