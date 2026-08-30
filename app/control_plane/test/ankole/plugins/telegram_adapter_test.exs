defmodule Ankole.Plugins.TelegramAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import Ankole.Eventually, only: [eventually: 1]

  alias Ankole.Plugins.TelegramAdapter

  alias Ankole.Plugins.TelegramAdapter.{
    ActionToken,
    Client,
    Config,
    ConnectionOwner,
    ConnectionReconciler,
    ConnectionSupervisor,
    Dispatcher,
    EntityText,
    ErrorPolicy,
    Inbound,
    Outbox,
    Presentation,
    ReplyPreview
  }

  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  alias Ankole.SignalsGateway.{
    ActorEvent,
    Actors,
    AdapterContext,
    Entry,
    OutboxEntry,
    ReplyInteractionState,
    ReplyPresentation
  }

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:ankole, Config)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ankole, Config)
      else
        Application.put_env(:ankole, Config, previous)
      end
    end)

    :ok
  end

  describe "plugin and catalog contract" do
    test "declares one consumer IM adapter with the complete gateway capability set" do
      assert TelegramAdapter.plugin_id() == "telegram-adapter"
      assert [declaration] = TelegramAdapter.adapter_declarations()
      assert declaration.id == "telegram"
      assert declaration.adapter_category == "consumer_im"

      assert declaration.supported_group_message_modes == [
               "addressed_only",
               "observe_all",
               "may_intervene"
             ]

      assert declaration.inbound_capabilities == [
               "entry_receive",
               "reaction_add",
               "reaction_remove",
               "action_event"
             ]

      assert declaration.outbound_capabilities == [
               "post_entry",
               "reply_entry",
               "edit_entry",
               "delete_entry",
               "add_reaction",
               "remove_reaction",
               "divider",
               "card"
             ]

      refute "outbound_reconciliation" in declaration.outbound_capabilities
      assert [%{path: "botToken", encrypted: true, required: true}] = declaration.fields
      assert Enum.all?(TelegramAdapter.app_config_patterns(), & &1.encrypted)
    end

    test "keeps two Agents' same-name bindings on distinct config keys" do
      key = Config.binding_config_key("agent-a", "main")
      assert key =~ ~r/\Asignals_gateway\.telegram\.bindings\.[a-f0-9]{64}\z/
      refute key == Config.binding_config_key("agent-b", "main")

      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()

      assert {:ok, %{binding: first_binding}} =
               SignalsGateway.put_binding(first.uid, "telegram", "main", %{
                 "config" => %{"botToken" => "111:first-secret"}
               })

      assert {:ok, %{binding: second_binding}} =
               SignalsGateway.put_binding(second.uid, "telegram", "main", %{
                 "config" => %{"botToken" => "222:second-secret"}
               })

      assert {:ok, %{"botToken" => "111:first-secret"}} =
               SignalsGateway.Bindings.stored_binding_config(first_binding)

      assert {:ok, %{"botToken" => "222:second-secret"}} =
               SignalsGateway.Bindings.stored_binding_config(second_binding)
    end

    test "validates the one required secret and redacts it from client inspection" do
      assert {:ok, %{"botToken" => "123456:secret-value"}} =
               Config.validate_binding_config(%{"botToken" => "123456:secret-value"})

      assert {:error, {:missing, "botToken"}} = Config.validate_binding_config(%{})

      client = Client.new("123456:secret-value")
      refute inspect(client) =~ "secret-value"
      assert inspect(client) =~ "[REDACTED]"

      runtime = %Config.Runtime{bot_token: "123456:secret-value"}
      refute inspect(runtime) =~ "secret-value"
      assert inspect(runtime) =~ "[REDACTED]"

      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{"code" => "telegram_delivery_unknown"}}} =
               ErrorPolicy.normalize_delivery_result({:error, :telegram_send_uncertain})
    end
  end

  describe "message chunking" do
    test "counts astral and ZWJ text in UTF-16 units without splitting graphemes" do
      prefix = String.duplicate("😀", 1_995)
      suffix = "👨‍👩‍👧‍👦tail"
      text = prefix <> suffix

      assert [^prefix, ^suffix] = assert_utf16_chunks(text, 4_000)
    end

    test "splits an oversized grapheme only between code points" do
      text = "😀" <> String.duplicate("\u0301", 3_999)
      assert [^text] = String.graphemes(text)

      assert [first, second] = assert_utf16_chunks(text, 4_000)
      assert utf16_units(first) == 4_000
      assert utf16_units(second) == 1
    end
  end

  describe "Bot API client and polling" do
    test "returns Telegram results and preserves retry_after without exposing transport details" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/bot123456:secret-value/getMe" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"id" => 42, "is_bot" => true}})

          "/bot123456:secret-value/sendMessage" ->
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{
              "ok" => false,
              "error_code" => 429,
              "description" => "Too Many Requests",
              "parameters" => %{"retry_after" => 7}
            })
        end
      end)

      client = test_client("123456:secret-value")
      assert {:ok, %{"id" => 42, "is_bot" => true}} = Client.call(client, "getMe")

      assert {:error,
              %Client.Error{
                kind: :api,
                error_code: 429,
                retry_after: 7,
                description: "Too Many Requests"
              }} = Client.call(client, "sendMessage", %{"chat_id" => 1, "text" => "hello"})

      assert {:error,
              {:reply_delivery, :retryable,
               %{"code" => "telegram_api_error", "retry_after_seconds" => 7}}} =
               ErrorPolicy.normalize_delivery_result(
                 {:error,
                  %Client.Error{
                    kind: :api,
                    error_code: 429,
                    description: nil,
                    retry_after: 7
                  }}
               )
    end

    test "advances the offset only through durable or explicitly ignored updates" do
      updates = Enum.map(10..12, &%{"update_id" => &1})

      dispatch = fn update, _consumer, _bot, _opts ->
        case update["update_id"] do
          10 -> {:ok, %{status: :accepted}}
          11 -> {:error, :database_unavailable}
          12 -> flunk("an update after a failure must not run")
        end
      end

      assert {:error, :database_unavailable, 11} =
               Dispatcher.process_updates(updates, %{}, %{}, nil, dispatch: dispatch)

      assert {:ok, 13} =
               Dispatcher.process_updates(updates, %{}, %{}, 10,
                 dispatch: fn _update, _consumer, _bot, _opts ->
                   {:ok, %{status: :ignored_unsupported_update}}
                 end
               )
    end

    test "advances past a permanently invalid Telegram message" do
      updates = [
        %{
          "update_id" => 10,
          "message" => %{
            "chat" => %{"id" => 501, "type" => "private"},
            "from" => %{"id" => 7001, "is_bot" => false}
          }
        },
        %{"update_id" => 11}
      ]

      assert {:ok, 12} =
               Dispatcher.process_updates(
                 updates,
                 consumer("owner-agent", "telegram-main"),
                 %{id: "77", username: "AnkoleBot"},
                 nil
               )
    end

    test "blocks a long-poll owner on an existing webhook and restarts it on token rotation" do
      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/getMe") ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"id" => 77, "is_bot" => true, "username" => "AnkoleBot"}
            })

          String.ends_with?(conn.request_path, "/getWebhookInfo") ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"url" => "https://example.test/telegram"}
            })
        end
      end)

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      consumer = consumer("owner-agent", "telegram-main")
      config = %{"botToken" => "100:first-secret"}

      assert {:ok, first} = ConnectionSupervisor.ensure_started(config, [consumer])
      assert eventually(fn -> ConnectionOwner.status(first).state == :blocked end)

      assert %{blocked_reason: :webhook_configured, bot_id: "77", polling?: false} =
               ConnectionOwner.status(first)

      assert {:ok, second} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "200:rotated-secret"}, [
                 consumer
               ])

      refute second == first
      refute Process.alive?(first)
      assert eventually(fn -> ConnectionOwner.status(second).state == :blocked end)
      assert :ok = ConnectionSupervisor.stop({"owner-agent", "telegram-main"})
    end

    test "keeps authentication failures in an operator-visible blocked state" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 401,
          "description" => "invalid token 707:auth-secret"
        })
      end)

      assert {:error, %Client.Error{description: "invalid token [REDACTED]"}} =
               Client.call(test_client("707:auth-secret"), "getMe")

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      key = {"auth-agent", "telegram-auth"}

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "707:auth-secret"}, [
                 consumer(elem(key, 0), elem(key, 1))
               ])

      assert eventually(fn -> ConnectionOwner.status(owner).state == :blocked end),
             inspect(ConnectionOwner.status(owner))

      assert %{
               blocked_reason: :authentication_failed,
               last_error: %{error_code: 401}
             } = ConnectionOwner.status(owner)

      refute inspect(ConnectionOwner.status(owner)) =~ "auth-secret"
      assert :ok = ConnectionSupervisor.stop(key)
    end
  end

  describe "inbound projection" do
    test "reads Telegram UTF-16 entity offsets without splitting supplementary characters" do
      assert EntityText.slice("😀 @AnkoleBot hi", 3, 10) == "@AnkoleBot"
      assert EntityText.slice("😀 @AnkoleBot hi", 0, 2) == "😀"
    end

    test "projects private, addressed group, and forum-topic messages with stable identities" do
      consumer = consumer("agent-a", "telegram-main")
      bot = %{id: "77", username: "AnkoleBot"}

      assert {:ok, dm} =
               Inbound.normalize_message_receive(
                 telegram_update(1, private_message(100, "hello"), bot),
                 consumer
               )

      assert dm.explicit
      assert dm.signal_channel_id == "telegram:77:chat:501"
      assert dm.author["provider"] == "telegram"
      assert dm.author["platform_subject"] == "100"
      refute Map.has_key?(dm.author, "email")

      command = "/stop@AnkoleBot now"

      group =
        group_message(101, command)
        |> Map.put("entities", [
          %{"type" => "bot_command", "offset" => 0, "length" => 15}
        ])

      assert {:ok, addressed} =
               Inbound.normalize_message_receive(telegram_update(2, group, bot), consumer)

      assert addressed.explicit
      assert addressed.text == "/stop now"

      # Removal follows the entity offsets, so an equal substring outside the
      # entity, here another username extending the bot's, stays intact.
      overlapping =
        group_message(103, "@AnkoleBot check @AnkoleBotNews now")
        |> Map.put("entities", [%{"type" => "mention", "offset" => 0, "length" => 10}])

      assert {:ok, mentioned} =
               Inbound.normalize_message_receive(telegram_update(4, overlapping, bot), consumer)

      assert mentioned.explicit
      assert mentioned.text == "check @AnkoleBotNews now"

      topic =
        group_message(102, "topic message")
        |> Map.merge(%{"message_thread_id" => 9001, "is_topic_message" => true})

      assert {:ok, normalized_topic} =
               Inbound.normalize_message_receive(telegram_update(3, topic, bot), consumer)

      assert normalized_topic.signal_channel_id == "telegram:77:chat:-100501:topic:9001"
      assert normalized_topic.provider_thread_id == normalized_topic.signal_channel_id
    end

    test "rejects channels, bots, anonymous senders, and Business messages" do
      consumer = consumer("agent-a", "telegram-main")
      bot = %{id: "77", username: "AnkoleBot"}

      channel = private_message(100, "hello") |> put_in(["chat", "type"], "channel")

      assert {:ignore, :unsupported_chat_type} =
               Inbound.normalize_message_receive(telegram_update(1, channel, bot), consumer)

      bot_message = private_message(100, "hello") |> put_in(["from", "is_bot"], true)

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_receive(telegram_update(2, bot_message, bot), consumer)

      anonymous = group_message(100, "hello") |> Map.put("sender_chat", %{"id" => -100_501})

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_receive(telegram_update(3, anonymous, bot), consumer)

      business = private_message(100, "hello") |> Map.put("business_connection_id", "biz-1")

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_receive(telegram_update(4, business, bot), consumer)
    end

    test "keeps an over-limit media fact but never invents a readable attachment path" do
      consumer = consumer("agent-a", "telegram-main")
      bot = %{id: "77", username: "AnkoleBot"}

      message =
        private_message(100, nil)
        |> Map.put("document", %{
          "file_id" => "large-file",
          "file_unique_id" => "unique-large-file",
          "file_name" => "archive.zip",
          "mime_type" => "application/zip",
          "file_size" => 21 * 1024 * 1024
        })

      assert {:ok, %{attachments: [attachment]}} =
               Inbound.normalize_message_receive(telegram_update(1, message, bot), consumer)

      assert attachment["materialization_state"] == "provider_download_limit"
      assert attachment["restriction"] =~ "20 MB"
      refute Map.has_key?(attachment, "attachment_id")
      refute Map.has_key?(attachment, "agent_computer_path")
      refute Map.has_key?(attachment, "user_files_relative_path")
    end

    test "assigns the durable attachment ID before writing an admitted file to user-files" do
      parent = self()
      %{principal: agent} = agent_fixture()

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:telegram_request, conn.request_path})

        case conn.request_path do
          "/bot606:media-secret/getFile" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"file_path" => "documents/report.txt", "file_size" => 10}
            })

          "/file/bot606:media-secret/documents/report.txt" ->
            Plug.Conn.send_resp(conn, 200, "attachment")
        end
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-media", %{
                 "config" => %{"botToken" => "606:media-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      route = "telegram-inbound-attachment-#{System.unique_integer([:positive])}"
      worker = insert_ready_worker!(route)
      route_auth = %{route: route, worker_id: worker.worker_id}
      {:ok, stored_path} = Agent.start_link(fn -> nil end)

      :ok =
        Broker.register_local_worker(route, fn
          {:file_transfer_lane, [protocol, "WRITE_OPEN", transfer_id, path, _size]} ->
            Agent.update(stored_path, fn _current -> path end)
            send(parent, {:materialized_attachment_path, path})

            FileTransferLane.handle_worker_frame(route_auth, [
              protocol,
              "WRITE_READY",
              transfer_id,
              u64(4 * 1024 * 1024)
            ])

          {:file_transfer_lane, [protocol, "DATA", transfer_id, _sequence, _offset, _eof, chunk]} ->
            FileTransferLane.handle_worker_frame(route_auth, [
              protocol,
              "CREDIT",
              transfer_id,
              u64(byte_size(chunk))
            ])

          {:file_transfer_lane, [protocol, "WRITE_COMMIT", transfer_id]} ->
            path = Agent.get(stored_path, & &1)

            FileTransferLane.handle_worker_frame(route_auth, [
              protocol,
              "WRITE_COMMITTED",
              transfer_id,
              path,
              u64(byte_size("attachment")),
              "8db84f6b892cfa6bdad930c907ecb808"
            ])
        end)

      on_exit(fn -> Broker.unregister_local_worker(route) end)

      message =
        private_message(9002, nil)
        |> Map.put("document", %{
          "file_id" => "report-file",
          "file_unique_id" => "report-unique",
          "file_name" => "report.txt",
          "mime_type" => "text/plain",
          "file_size" => 10
        })

      assert {:ok, [result]} =
               Inbound.handle_message_receive(
                 "message",
                 telegram_update(1, message, %{id: "606", username: "AnkoleBot"}),
                 [
                   consumer(agent.uid, "telegram-media", %{
                     "botToken" => "606:media-secret"
                   })
                 ]
               )

      assert %Entry{attachments: [attachment]} = result.signal_entry
      assert_received {:telegram_request, "/bot606:media-secret/getFile"}
      assert_received {:telegram_request, "/file/bot606:media-secret/documents/report.txt"}
      assert is_integer(attachment["attachment_id"])
      assert attachment["materialization_state"] == "complete"

      expected_relative = "inbox/#{attachment["attachment_id"]}/report.txt"

      assert attachment["user_files_relative_path"] == expected_relative

      assert attachment["agent_computer_path"] ==
               "/agents/#{agent.uid}/user-files/#{expected_relative}"

      expected_lane = "/user_files/#{agent.uid}/user-files/#{expected_relative}"
      assert_receive {:materialized_attachment_path, ^expected_lane}
    end

    test "deduplicates an update delivered again before Telegram receives the next offset" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-redelivery", %{
                 "config" => %{"botToken" => "707:redelivery-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      update =
        telegram_update(
          70,
          private_message(9_070, "deliver once"),
          %{id: "707", username: "AnkoleBot"}
        )

      telegram_consumer = consumer(agent.uid, "telegram-redelivery")

      assert {:ok, [_first]} =
               Inbound.handle_message_receive("message", update, [telegram_consumer])

      assert {:ok, [_duplicate]} =
               Inbound.handle_message_receive("message", update, [telegram_consumer])

      assert Repo.aggregate(Entry, :count) == 1
    end

    test "folds Telegram reaction deltas into the mirrored entry" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-reactions", %{
                 "config" => %{"botToken" => "505:reaction-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      bot = %{id: "505", username: "AnkoleBot"}
      message = private_message(9001, "react here")
      consumer = consumer(agent.uid, "telegram-reactions")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 telegram_update(1, message, bot),
                 [consumer]
               )

      update = %{
        "update_id" => 2,
        "bot" => bot,
        "message_reaction" => %{
          "chat" => message["chat"],
          "message_id" => message["message_id"],
          "user" => message["from"],
          "date" => message["date"],
          "old_reaction" => [],
          "new_reaction" => [%{"type" => "emoji", "emoji" => "👍"}]
        }
      }

      assert {:ok, [%{added: [%{status: :mirrored}], removed: []}]} =
               Inbound.handle_reaction_update("message_reaction", update, [consumer])

      entry =
        Repo.get_by!(Entry,
          signal_channel_id: "telegram:505:chat:501",
          source_entry_id: Integer.to_string(message["message_id"])
        )

      assert entry.reactions == %{"👍" => ["9001"]}
      assert entry.raw_reaction_keys == %{"👍" => "👍"}
    end

    test "keeps a reaction out of another chat whose id extends the reacted chat's" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-chat-ids", %{
                 "config" => %{"botToken" => "505:chat-id-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      bot = %{id: "505", username: "AnkoleBot"}
      consumer = consumer(agent.uid, "telegram-chat-ids")

      # The recorded message lives in chat 5012; the reaction arrives from
      # chat 501, whose channel id is a string prefix of chat 5012's.
      message = private_message(9001, "react target") |> put_in(["chat", "id"], 5012)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", telegram_update(1, message, bot), [
                 consumer
               ])

      update = %{
        "update_id" => 2,
        "bot" => bot,
        "message_reaction" => %{
          "chat" => %{"id" => 501, "type" => "private", "username" => "ada"},
          "message_id" => message["message_id"],
          "user" => message["from"],
          "date" => message["date"],
          "old_reaction" => [],
          "new_reaction" => [%{"type" => "emoji", "emoji" => "👍"}]
        }
      }

      assert {:ok, [_result]} =
               Inbound.handle_reaction_update("message_reaction", update, [consumer])

      entry =
        Repo.get_by!(Entry,
          signal_channel_id: "telegram:505:chat:5012",
          source_entry_id: Integer.to_string(message["message_id"])
        )

      assert entry.reactions == %{}
    end
  end

  describe "identity admission" do
    test "manual review maps Telegram users to humans with or without a LocalPassword credential" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-main", %{
                 "config" => %{"botToken" => "101:manual-review-secret"},
                 "unmatched_sender_policy" => "manual_review"
               })

      consumer = consumer(agent.uid, "telegram-main")
      bot = %{id: "101", username: "AnkoleBot"}
      first_update = telegram_update(1, private_message(7001, "hello"), bot)

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               Inbound.handle_message_receive(
                 "message",
                 first_update,
                 [consumer]
               )

      assert [request] = MappingRequests.list_requests()
      assert request.provider == "telegram"
      assert request.external_id == "7001"
      assert Repo.aggregate(Entry, :count) == 0

      assert %OutboxEntry{
               operation: :reply,
               reply_to_source_entry_id: reply_to_source_entry_id,
               fallback_visible_text: notice
             } = Repo.one!(OutboxEntry)

      assert reply_to_source_entry_id == private_message_source_entry_id(first_update)

      assert notice == Ankole.I18n.t("signals_gateway.reply.unmapped_sender")

      %{principal: local_human} = human_fixture()

      assert {:ok, _credential} =
               Ankole.IdentityProviders.LocalPassword.set_local_password(
                 local_human.uid,
                 "local-secret",
                 false
               )

      assert {:ok, _mapping} = MappingRequests.bind_request(request.id, local_human.uid)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 telegram_update(2, private_message(7001, "resend"), bot),
                 [consumer]
               )

      assert {:ok, matched_local} = Principals.resolve_platform_subject("telegram", "7001")
      assert matched_local.uid == local_human.uid

      %{principal: ordinary_human} = human_fixture()

      assert {:ok, _identity} =
               MappingRequests.bind_subject(ordinary_human.uid, %{
                 provider: "telegram",
                 external_id: "7002"
               })

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 telegram_update(3, private_message(7002, "hello"), bot),
                 [consumer]
               )

      assert {:ok, matched_ordinary} = Principals.resolve_platform_subject("telegram", "7002")
      assert matched_ordinary.uid == ordinary_human.uid
    end

    test "create_standalone stays the generic binding policy" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-standalone", %{
                 "config" => %{"botToken" => "202:standalone-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      bot = %{id: "202", username: "AnkoleBot"}

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 telegram_update(1, private_message(8001, "hello"), bot),
                 [consumer(agent.uid, "telegram-standalone")]
               )

      assert {:ok, principal} = Principals.resolve_platform_subject("telegram", "8001")
      assert principal.type == :human
    end

    test "one bot token can belong to only one enabled binding" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()

      attrs = %{"config" => %{"botToken" => "303:exclusive-secret"}}

      assert {:ok, _binding} =
               SignalsGateway.put_binding(first_agent.uid, "telegram", "telegram-one", attrs)

      assert {:error, {:telegram_bot_token_already_bound, first_uid, "telegram-one"}} =
               SignalsGateway.put_binding(second_agent.uid, "telegram", "telegram-two", attrs)

      assert first_uid == first_agent.uid

      assert {:ok, _disabled} =
               SignalsGateway.disable_binding(first_agent.uid, "telegram-one")

      assert {:ok, _binding} =
               SignalsGateway.put_binding(second_agent.uid, "telegram", "telegram-two", attrs)
    end

    test "the reconciler stops the owner after its binding is disabled" do
      %{principal: agent} = agent_fixture()
      config = %{"botToken" => "808:disable-secret"}

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/bot808:disable-secret/getMe" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"id" => 808, "is_bot" => true, "username" => "AnkoleBot"}
            })

          "/bot808:disable-secret/getWebhookInfo" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"url" => "https://example.test/telegram"}
            })
        end
      end)

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-disabled", %{
                 "config" => config
               })

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(config, [
                 consumer(agent.uid, "telegram-disabled", config)
               ])

      assert eventually(fn -> ConnectionOwner.status(owner).state == :blocked end)
      assert {:ok, _binding} = SignalsGateway.disable_binding(agent.uid, "telegram-disabled")
      assert %{stopped: 1, errors: []} = ConnectionReconciler.reconcile_once()
      refute Process.alive?(owner)
    end
  end

  describe "actions and outbound" do
    test "checkpoints one mutable reply and edits the same Telegram message" do
      parent = self()
      %{principal: agent} = agent_fixture()

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:telegram_request, conn.request_path})

        case conn.request_path do
          "/bot909:preview-secret/sendMessage" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"message_id" => 900, "date" => 1_787_000_000}
            })

          "/bot909:preview-secret/editMessageText" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{
                "message_id" => 900,
                "date" => 1_787_000_000,
                "edit_date" => 1_787_000_001
              }
            })
        end
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-preview", %{
                 "config" => %{"botToken" => "909:preview-secret"}
               })

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(
          agent.uid,
          "telegram-preview",
          %{
            source_event_id: "preview-event",
            signal_channel_id: "telegram:909:chat:501",
            source_entry_id: "50",
            channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
            text: "hello",
            explicit: true,
            author: %{principal_uid: "human-a", id: "7001"},
            provider_time: base_time()
          }
        )

      presentation =
        ReplyPresentation.new(state: "working")
        |> ReplyPresentation.replace_answer("draft")

      request = %Request{
        actor_event: event,
        presentation: presentation,
        checkpoint: nil,
        subject_uid: "human-a",
        conversation_id: "conversation-a",
        mode: :working
      }

      assert {:ok, first} = ReplyPreview.update(request)
      assert first.created_source_entry_id == "900"

      assert first.reply_preview_checkpoint["messages"] == [
               %{"index" => 0, "message_id" => "900"}
             ]

      assert_received {:telegram_request, "/bot909:preview-secret/sendMessage"}

      updated = ReplyPresentation.replace_answer(presentation, "final draft")

      assert {:ok, second} =
               ReplyPreview.update(%{
                 request
                 | presentation: updated,
                   checkpoint: first.reply_preview_checkpoint
               })

      assert second.created_source_entry_id == "900"
      assert_received {:telegram_request, "/bot909:preview-secret/editMessageText"}
    end

    test "reposts a deleted checkpointed message with the original reply anchor" do
      parent = self()
      %{principal: agent} = agent_fixture()

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:telegram_request, conn.request_path, Torque.decode!(raw_body)})

        case conn.request_path do
          "/bot909:repost-secret/editMessageText" ->
            Req.Test.json(conn, %{
              "ok" => false,
              "error_code" => 400,
              "description" => "Bad Request: message to edit not found"
            })

          "/bot909:repost-secret/sendMessage" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"message_id" => 901, "date" => 1_787_000_000}
            })
        end
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-repost", %{
                 "config" => %{"botToken" => "909:repost-secret"}
               })

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(
          agent.uid,
          "telegram-repost",
          %{
            source_event_id: "repost-event",
            signal_channel_id: "telegram:909:chat:501",
            source_entry_id: "50",
            channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
            text: "hello",
            explicit: true,
            author: %{principal_uid: "human-a", id: "7001"},
            provider_time: base_time()
          }
        )

      request = %Request{
        actor_event: event,
        presentation:
          ReplyPresentation.new(state: "working")
          |> ReplyPresentation.replace_answer("recovered draft"),
        checkpoint: %{
          "message_id" => "900",
          "messages" => [%{"index" => 0, "message_id" => "900"}]
        },
        subject_uid: "human-a",
        conversation_id: "conversation-a",
        mode: :working
      }

      assert {:ok, result} = ReplyPreview.update(request)
      assert result.created_source_entry_id == "901"

      assert_received {:telegram_request, "/bot909:repost-secret/editMessageText", _edit_body}
      assert_received {:telegram_request, "/bot909:repost-secret/sendMessage", send_body}

      assert send_body["reply_parameters"] == %{
               "message_id" => 50,
               "allow_sending_without_reply" => true
             }
    end

    test "uses a sub-64-byte callback token and restores the complete action from a checkpoint" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "telegram-action", :ignore, adapter: "telegram")

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(
          agent.uid,
          "telegram-action",
          %{
            source_event_id: "event-1",
            signal_channel_id: "telegram:77:chat:501",
            source_entry_id: "50",
            channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
            text: "hello",
            explicit: true,
            author: %{principal_uid: "human-a", id: "7001"},
            provider_time: base_time()
          }
        )

      presentation =
        ReplyPresentation.new(state: "awaiting_input")
        |> Map.merge(%{
          "interaction_status" => "pending",
          "actions" => [
            %{
              "type" => "button",
              "id" => "approve",
              "label" => "Approve",
              "interaction_id" => "interaction-1",
              "source_actor_event_id" => event.id,
              "control_id" => "approve",
              "selected_option_id" => "yes",
              "option_value" => "approved",
              "revision" => 3
            }
          ]
        })

      checkpoint =
        %{
          "message_id" => "900",
          "messages" => [%{"index" => 0, "message_id" => "900"}]
        }
        |> ReplyInteractionState.initialize(presentation, base_time())

      assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
      assert {:ok, token} = ActionToken.encode(event.id, 0, hd(presentation["actions"]))
      assert byte_size(token) < 64

      assert {:ok, value} = ActionToken.resolve(token, agent.uid, "telegram-action", "900")
      assert value["version"] == "ankole.interactive_output.action.v1"
      assert value["sourceActorEventId"] == event.id
      assert value["optionValue"] == "approved"

      # A forged event id must fail as an invalid token, not raise in the
      # event lookup: a raise would wedge the poll loop on the same update.
      assert {:error, :invalid_callback_token} =
               ActionToken.resolve(
                 "tg1:not-a-uuid:0:AAAAAAAAAAA",
                 agent.uid,
                 "telegram-action",
                 "900"
               )

      changed_checkpoint =
        put_in(
          checkpoint,
          ["presentation", "actions", Access.at(0), "option_value"],
          "changed-after-render"
        )

      assert {:ok, _event} =
               Actors.put_reply_preview_checkpoint(event.id, changed_checkpoint)

      assert {:error, :invalid_callback_action} =
               ActionToken.resolve(token, agent.uid, "telegram-action", "900")

      assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)

      assert {:ok, [%{"reply_markup" => markup}]} = Presentation.render(presentation, event.id)

      assert get_in(markup, ["inline_keyboard", Access.at(0), Access.at(0), "callback_data"]) ==
               token

      %{principal: operator} = human_fixture()

      assert {:ok, _identity} =
               MappingRequests.bind_subject(operator.uid, %{
                 provider: "telegram",
                 external_id: "7001"
               })

      callback = %{
        "update_id" => 2,
        "bot" => %{id: "77", username: "AnkoleBot"},
        "callback_query" => %{
          "id" => "callback-1",
          "data" => token,
          "from" => %{"id" => 7001, "is_bot" => false, "first_name" => "Ada"},
          "message" => %{
            "message_id" => 900,
            "chat" => %{"id" => 501, "type" => "private"}
          }
        }
      }

      assert {:ok, [%{status: :accepted, actor_event: action_event}]} =
               Inbound.handle_card_action("callback_query", callback, [
                 consumer(agent.uid, "telegram-action")
               ])

      assert action_event.type == "signal.action.invoked"
    end

    test "builds every declared outbound operation against the original adapter channel" do
      base = %OutboxEntry{
        agent_uid: "agent-a",
        binding_name: "telegram-main",
        outbound_key: "out-1",
        operation: :post,
        signal_channel_id: "telegram:77:chat:-100501:topic:9001",
        payload: %{},
        fallback_visible_text: "hello"
      }

      for operation <- [
            :post,
            :reply,
            :edit,
            :delete,
            :reaction_add,
            :reaction_remove,
            :divider,
            :card
          ] do
        outbox =
          %{base | operation: operation}
          |> Map.put(:reply_to_source_entry_id, if(operation == :reply, do: "42"))
          |> Map.put(
            :target_source_entry_id,
            if(operation in [:edit, :delete, :reaction_add, :reaction_remove], do: "42")
          )
          |> Map.put(
            :payload,
            if(operation in [:reaction_add, :reaction_remove],
              do: %{"reaction_key" => "thumbsup"},
              else: %{}
            )
          )

        assert {:ok, [_request | _rest]} = Outbox.requests_for_outbox(outbox)
      end

      assert {:ok, [%{body: body}]} = Outbox.requests_for_outbox(base)
      assert body["chat_id"] == "-100501"
      assert body["message_thread_id"] == 9001
      assert body["text"] == "hello"
    end

    test "sends a reply attachment without adding an empty text message" do
      outbox = %OutboxEntry{
        agent_uid: "agent-a",
        binding_name: "telegram-main",
        outbound_key: "attachment-1",
        operation: :reply,
        signal_channel_id: "telegram:77:chat:501",
        reply_to_source_entry_id: "42",
        payload: %{
          "attachments" => [
            %{
              "provider_file_id" => "telegram-file-id",
              "name" => "report.pdf",
              "mime_type" => "application/pdf"
            }
          ]
        },
        fallback_visible_text: ""
      }

      assert {:ok, [%{method: "sendDocument", body: body}]} =
               Outbox.requests_for_outbox(outbox)

      assert body["document"] == "telegram-file-id"
      assert body["reply_parameters"] == %{"message_id" => 42}
      refute Map.has_key?(body, "caption")
    end

    test "sends a canonical image attachment as a Telegram photo" do
      outbox = %OutboxEntry{
        agent_uid: "agent-a",
        binding_name: "telegram-main",
        outbound_key: "attachment-image-1",
        operation: :post,
        signal_channel_id: "telegram:77:chat:501",
        payload: %{
          "attachments" => [
            %{
              "provider_file_id" => "telegram-image-id",
              "name" => "image.png",
              "mime_type" => "image/png"
            }
          ]
        },
        fallback_visible_text: ""
      }

      assert {:ok, [%{method: "sendPhoto", body: body}]} =
               Outbox.requests_for_outbox(outbox)

      assert body["photo"] == "telegram-image-id"
    end

    test "returns unknown when a non-idempotent provider send has an uncertain result" do
      %{principal: agent} = agent_fixture()

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-unknown", %{
                 "config" => %{"botToken" => "404:uncertain-secret"}
               })

      assert :unknown =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "telegram-unknown",
                 outbound_key: "unknown-1",
                 operation: :post,
                 signal_channel_id: "telegram:404:chat:501",
                 payload: %{},
                 fallback_visible_text: "hello"
               })
    end

    test "returns unknown after one chunk succeeds and a later chunk is uncertain" do
      %{principal: agent} = agent_fixture()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://telegram.test", plug: {Req.Test, __MODULE__}]
      )

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"message_id" => 1, "date" => 1_787_000_000}
            })

          _later ->
            Req.Test.transport_error(conn, :timeout)
        end
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "telegram", "telegram-partial", %{
                 "config" => %{"botToken" => "405:partial-secret"}
               })

      assert :unknown =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "telegram-partial",
                 outbound_key: "partial-1",
                 operation: :post,
                 signal_channel_id: "telegram:405:chat:501",
                 payload: %{},
                 fallback_visible_text: String.duplicate("x", 4_001)
               })

      assert Agent.get(attempts, & &1) == 2
    end
  end

  defp consumer(agent_uid, binding_name, config \\ %{"botToken" => "test-only-token"}) do
    Inbound.chat_consumer(
      AdapterContext.new(
        agent_uid: agent_uid,
        binding_name: binding_name,
        adapter: "telegram",
        user_name: "Telegram"
      ),
      config
    )
  end

  defp telegram_update(update_id, message, bot),
    do: %{"update_id" => update_id, "message" => message, "bot" => bot}

  defp private_message_source_entry_id(%{"message" => %{"message_id" => message_id}}),
    do: Integer.to_string(message_id)

  defp private_message(user_id, text) do
    %{
      "message_id" => System.unique_integer([:positive]),
      "date" => 1_787_000_000,
      "chat" => %{"id" => 501, "type" => "private", "username" => "ada"},
      "from" => %{
        "id" => user_id,
        "is_bot" => false,
        "first_name" => "Ada",
        "username" => "ada#{user_id}",
        "language_code" => "en"
      },
      "text" => text
    }
  end

  defp group_message(user_id, text) do
    private_message(user_id, text)
    |> Map.put("chat", %{
      "id" => -100_501,
      "type" => "supergroup",
      "title" => "Ankole Ops",
      "is_forum" => true
    })
  end

  defp test_client(token) do
    Client.new(token,
      base_url: "https://telegram.test",
      plug: {Req.Test, __MODULE__}
    )
  end

  defp insert_ready_worker!(route) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: "telegram-worker-#{System.unique_integer([:positive])}",
      incarnation_id: Ecto.UUID.generate(),
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })
  end

  defp assert_utf16_chunks(text, budget) do
    chunks = Presentation.chunks(text)

    assert Enum.join(chunks) == text
    assert Enum.all?(chunks, &String.valid?/1)
    assert Enum.all?(chunks, &(length(String.codepoints(&1)) <= budget))
    assert Enum.all?(chunks, &(utf16_units(&1) <= budget))

    chunks
  end

  defp utf16_units(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp u64(value), do: <<value::unsigned-big-integer-size(64)>>
end
