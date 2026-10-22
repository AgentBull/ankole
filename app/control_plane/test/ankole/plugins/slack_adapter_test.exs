defmodule Ankole.Plugins.SlackAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.ExternalConversationsFixtures
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures
  import Ankole.Eventually, only: [eventually: 1]

  alias Ankole.AppConfigure
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.Plugins.SlackAdapter

  alias Ankole.Plugins.SlackAdapter.BlockKit
  alias Ankole.Plugins.SlackAdapter.Channels
  alias Ankole.Plugins.SlackAdapter.Config
  alias Ankole.Plugins.SlackAdapter.ConnectionReconciler
  alias Ankole.Plugins.SlackAdapter.Dispatcher
  alias Ankole.Plugins.SlackAdapter.Emoji
  alias Ankole.Plugins.SlackAdapter.ErrorPolicy
  alias Ankole.Plugins.SlackAdapter.IdentityProvider
  alias Ankole.Plugins.SlackAdapter.Inbound
  alias Ankole.Plugins.SlackAdapter.Mrkdwn
  alias Ankole.Plugins.SlackAdapter.Delivery

  alias Ankole.Repo

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request
  alias SlackOpenAPI.Event
  alias SlackOpenAPI.SocketMode.Dispatcher, as: SocketDispatcher

  setup do
    previous = Req.default_options()
    Req.default_options(plug: &stub_slack_download/1)
    on_exit(fn -> Req.default_options(previous) end)
    :ok
  end

  describe "plugin and config contracts" do
    test "dispatches app mentions through the message receiver" do
      %{principal: agent} = agent_fixture()
      config = chat_config(%{"botUserID" => "UBOT"})

      context =
        AdapterContext.new(
          agent_uid: agent.uid,
          binding_name: "main",
          adapter: "slack",
          user_name: "Slack"
        )

      consumer = Inbound.chat_consumer(context, config) |> Map.put(:tenant_id, Repo.tenant_id!())
      dispatcher = Dispatcher.build([consumer])

      envelope =
        {:envelope,
         %{
           "type" => "events_api",
           "payload" => %{"event" => %{"type" => "app_mention"}}
         }}

      assert {:ok, [%{status: :ignored_missing_platform_subject}]} =
               SocketDispatcher.dispatch(dispatcher, envelope)
    end

    test "declares chat and identity contracts" do
      assert SlackAdapter.plugin_id() == "slack-adapter"

      assert [
               %{contract_id: "signals.adapter", id: "slack", config_module: Config},
               %{
                 contract_id: "principals.identity_provider",
                 id: "slack",
                 module: IdentityProvider
               }
             ] = SlackAdapter.adapter_declarations()

      assert Enum.all?(SlackAdapter.app_config_patterns(), & &1.encrypted)

      [_chat, identity] = SlackAdapter.adapter_declarations()
      fields = Map.new(identity.fields, &{&1.path, &1})

      assert fields["botToken"].requiredWhen == [%{path: "sync.contacts", value: true}]
      assert fields["botToken"].validation.pattern == "^xoxb-"

      assert fields["appToken"].requiredWhen == [
               %{path: "sync.contacts", value: true},
               %{path: "sync.websocket", value: true}
             ]

      assert fields["appToken"].validation.pattern == "^xapp-"
    end

    test "chat validation enforces token types and stable fingerprints" do
      assert {:error, {:invalid_token_prefix, "botToken"}} =
               Config.validate_chat_config(%{"botToken" => "xapp-wrong", "appToken" => "xapp-ok"})

      assert {:error, {:invalid_token_prefix, "appToken"}} =
               Config.validate_chat_config(%{"botToken" => "xoxb-ok", "appToken" => "xoxb-wrong"})

      assert {:ok, config} = Config.validate_chat_config(chat_config())
      assert Config.subject_namespace(config) == "slack-main"
      assert {"slack", fingerprint} = Config.connection_key(config)
      assert byte_size(fingerprint) == 16
      assert Config.connection_key(config) == Config.connection_key(config)

      assert Config.secret_fingerprint(config) !=
               Config.secret_fingerprint(%{config | "botToken" => "xoxb-other"})
    end

    test "stored config cannot override the provider endpoint" do
      previous = Application.fetch_env(:ankole, Config)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ankole, Config, value)
          :error -> Application.delete_env(:ankole, Config)
        end
      end)

      assert {:ok, config} =
               Config.validate_chat_config(
                 Map.put(chat_config(), "baseURL", "https://stored.invalid")
               )

      refute Map.has_key?(config, "baseURL")
      assert Config.client(config).base_url == "https://slack.com/api"

      Application.put_env(:ankole, Config, client_opts: [base_url: "https://test.invalid"])
      assert Config.client(config).base_url == "https://test.invalid"

      assert Config.client(config, base_url: "https://explicit.invalid").base_url ==
               "https://explicit.invalid"
    end

    test "identity validation enforces sync credential dependencies" do
      assert {:error, {:missing, "botToken"}} =
               Config.validate_identity_config(%{"clientID" => "c", "clientSecret" => "s"})

      assert {:error, {:missing, "appToken"}} =
               Config.validate_identity_config(%{
                 "clientID" => "c",
                 "clientSecret" => "s",
                 "botToken" => "xoxb-bot"
               })

      assert {:ok, config} =
               Config.validate_identity_config(%{
                 "clientID" => "c",
                 "clientSecret" => "s",
                 "sync" => %{"contacts" => false, "websocket" => true}
               })

      assert config["sync"]["contacts"] == false
      assert config["sync"]["websocket"] == false
      assert config["sync"]["pageSize"] == 200
    end

    test "runtime bot identity verifies the application without persisting it" do
      {:ok, config} = Config.validate_chat_config(chat_config())

      Req.default_options(
        plug: fn conn ->
          case conn.request_path do
            "/api/auth.test" ->
              Req.Test.json(conn, %{
                "ok" => true,
                "user_id" => "UBOT",
                "bot_id" => "B1",
                "team_id" => "T1"
              })

            "/api/bots.info" ->
              Req.Test.json(conn, %{"ok" => true, "bot" => %{"id" => "B1", "app_id" => "A1"}})
          end
        end
      )

      assert {:ok, resolved} = Config.resolve_runtime_bot_identity(config)

      assert resolved["runtimeBotUserID"] == "UBOT"
      assert resolved["runtimeBotID"] == "B1"
      assert resolved["runtimeAppID"] == "A1"
      assert resolved["runtimeTeamID"] == "T1"
      assert resolved["botUserID"] == nil
    end
  end

  describe "pure provider rendering" do
    test "mrkdwn conversion preserves code and converts markdown deterministically" do
      input =
        "# Heading\n\n**bold** and *italic* and ~~gone~~\n[label](https://example.com)\n- item\n| a | b |\n| - | - |\n`**code**`"

      output = Mrkdwn.from_markdown(input)

      assert output =~ "*Heading*"
      assert output =~ "*bold* and _italic_ and ~gone~"
      assert output =~ "<https://example.com|label>"
      assert output =~ "• item"
      assert output =~ "```\n| a | b |\n| - | - |\n```"
      assert output =~ "`**code**`"
    end

    test "Block Kit renders portable interactive output and splits at provider limits" do
      payload = %{
        "interactive_output" => %{
          "title" => "Decision",
          "body" => "**Choose**",
          "facts" => [%{"label" => "Owner", "value" => "Ada"}],
          "choices" => [%{"label" => "Approve", "value" => "yes"}],
          "state" => "Waiting"
        }
      }

      assert {:ok, blocks} = BlockKit.render(payload)
      assert Enum.any?(blocks, &(&1["type"] == "header"))
      assert Enum.any?(blocks, &(&1["type"] == "actions"))

      button =
        blocks |> Enum.find(&(&1["type"] == "actions")) |> get_in(["elements", Access.at(0)])

      assert Torque.decode!(button["value"]) == %{
               "v" => "ankole.interactive_output.action.v1",
               "value" => "yes"
             }

      assert [first, second] = BlockKit.split_blocks(List.duplicate(%{"type" => "divider"}, 51))
      assert length(first) == 50
      assert length(second) == 1
    end

    test "Block Kit renders Slack reply state and durable choice callbacks" do
      presentation = %{
        "state" => "awaiting_input",
        "prompt" => "Choose one",
        "interaction_status" => "pending",
        "actions" => [
          %{
            "type" => "button",
            "id" => "approve",
            "label" => "Approve",
            "style" => "primary",
            "interaction_id" => "interaction-1",
            "source_signal_id" => "019fbd9e-5800-7000-8000-000000000001",
            "control_id" => "decision",
            "selected_option_id" => "approve",
            "option_value" => "yes",
            "revision" => 4
          }
        ]
      }

      assert {:ok, blocks} = BlockKit.render(%{"reply_presentation" => presentation})

      button =
        blocks |> Enum.find(&(&1["type"] == "actions")) |> get_in(["elements", Access.at(0)])

      assert button["style"] == "primary"

      assert Torque.decode!(button["value"]) == %{
               "version" => "ankole.interactive_output.action.v1",
               "answerKind" => "choice",
               "interactionId" => "interaction-1",
               "interactionVersion" => 4,
               "controlId" => "decision",
               "selectedOptionId" => "approve",
               "optionValue" => "yes",
               "sourceSignalId" => "019fbd9e-5800-7000-8000-000000000001"
             }
    end

    test "Block Kit does not retain a working status after the reply terminates" do
      for {state, expected_status} <- [
            {"completed", nil},
            {"failed", "Failed"},
            {"stopped", "Stopped"},
            {"awaiting_input", "Waiting for input"},
            {"scheduled", "Scheduled"}
          ] do
        presentation = %{
          "state" => state,
          "answer" => "Done",
          "meta" => %{"status" => "正在理解请求"}
        }

        assert {:ok, blocks} = BlockKit.render(%{"reply_presentation" => presentation})
        rendered = Torque.encode!(blocks)

        refute rendered =~ "正在理解请求"
        assert rendered =~ "Done"

        if expected_status do
          assert rendered =~ expected_status
        end
      end
    end

    test "Block Kit localizes the Slack-owned starting state" do
      {:ok, _locale} = Ankole.I18n.put_default_locale("zh-Hans-CN")

      assert {:ok, blocks} =
               BlockKit.render(%{
                 "reply_presentation" => %{"state" => "debouncing", "answer" => ""}
               })

      rendered = Torque.encode!(blocks)
      assert rendered =~ "正在接收请求"
      refute rendered =~ "Starting"
    end

    test "emoji mapping strips skin tone and round-trips stable keys" do
      assert Emoji.normalize("thumbsup::skin-tone-3") == "thumbs_up"
      assert Emoji.normalize("custom") == "custom"
      assert Emoji.provider_key("thumbs_up") == "thumbsup"
    end
  end

  describe "inbound and intent normalization" do
    test "blocks missing Slack scopes with the required scope visible" do
      error = %SlackOpenAPI.Error{
        reason: "missing_scope",
        status: 200,
        raw: %{
          "needed" => "files:write",
          "provided" => "chat:write,files:read",
          "token" => "must-not-be-stored"
        }
      }

      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{
                 "code" => "missing_scope",
                 "http_status" => 200,
                 "needed_scope" => "files:write"
               }}} = ErrorPolicy.normalize_delivery_result({:error, error})
    end

    test "keeps transient Slack failures retryable" do
      assert {:error,
              {:reply_delivery, :retryable,
               %{"code" => "rate_limited", "retry_after_seconds" => 30}}} =
               ErrorPolicy.normalize_delivery_result({:error, {:rate_limited, 30}})

      assert {:error,
              {:reply_delivery, :retryable, %{"code" => "transport", "http_status" => 503}}} =
               ErrorPolicy.normalize_delivery_result(
                 {:error, %SlackOpenAPI.Error{reason: :transport, status: 503}}
               )
    end

    test "normalizes group mention, thread, files and Slack link text" do
      consumer = chat_consumer(%{"runtimeBotUserID" => "UBOT"})

      event =
        event(%{
          "channel" => "C1",
          "channel_type" => "channel",
          "user" => "U1",
          "text" => "<@UBOT> review <@U2> <https://example.com|doc>",
          "ts" => "1700000000.000100",
          "thread_ts" => "1699999999.000001",
          "files" => [
            %{
              "id" => "F1",
              "name" => "a.txt",
              "url_private" => "https://files.test/F1",
              "mimetype" => "text/plain",
              "size" => 3
            }
          ]
        })

      assert {:ok, normalized} = Inbound.normalize_message_receive(event, consumer)
      assert normalized.provider_conversation_id == "slack:C1"
      assert normalized.provider_thread_id == "slack:C1:1699999999.000001"
      assert normalized.reply_to_provider_message_id == "1699999999.000001"
      assert normalized.explicit == true
      assert normalized.text =~ "review @U2 doc (https://example.com)"
      assert [%{"provider_ref" => "slack:file:F1"}] = normalized.attachments
      assert [%{"agent_uid" => "agent-1"}, _other] = normalized.mentions
    end

    test "top-level messages carry no provider thread id" do
      consumer = chat_consumer(%{"runtimeBotUserID" => "UBOT"})

      event =
        event(%{
          "channel" => "C1",
          "channel_type" => "channel",
          "user" => "U1",
          "text" => "plain channel message",
          "ts" => "1700000000.000200"
        })

      assert {:ok, normalized} = Inbound.normalize_message_receive(event, consumer)
      assert is_nil(normalized.provider_thread_id)
      assert is_nil(normalized.reply_to_provider_message_id)

      root_event = %{event | content: Map.put(event.content, "thread_ts", "1700000000.000200")}

      assert {:ok, root} = Inbound.normalize_message_receive(root_event, consumer)
      assert is_nil(root.provider_thread_id)
      assert is_nil(root.reply_to_provider_message_id)
    end

    test "ignores bot senders, changed messages, and routes deletion payloads" do
      consumer = chat_consumer(%{"runtimeBotUserID" => "UBOT"})

      assert {:ignore, :provider_self_sender} =
               Inbound.normalize_message_receive(
                 event(%{"channel" => "C1", "user" => "UBOT", "text" => "self", "ts" => "1.1"}),
                 consumer
               )

      changed = event(%{"subtype" => "message_changed"})

      assert {:ok, [%{status: :ignored_message_changed}]} =
               Inbound.handle_message_receive("message", changed, [consumer])
    end

    test "builds every Slack intent request shape" do
      base = %Intent{
        conversation_id: external_conversation_id("slack:C1"),
        payload: %{},
        fallback_visible_text: "**hello**"
      }

      assert {:ok,
              [%{method: "chat.postMessage", body: %{"channel" => "C1", "text" => "*hello*"}}]} =
               Delivery.requests_for_intent(%{base | operation: :post})

      assert {:ok, [%{body: %{"thread_ts" => "1.1"}}]} =
               Delivery.requests_for_intent(%{
                 base
                 | operation: :reply,
                   reply_to_provider_message_id: "1.1"
               })

      assert {:ok, [%{method: "chat.update"}]} =
               Delivery.requests_for_intent(%{
                 base
                 | operation: :edit,
                   target_provider_message_id: "1.1"
               })

      assert {:ok, [%{method: "reactions.add", body: %{"name" => "thumbsup"}}]} =
               Delivery.requests_for_intent(%{
                 base
                 | operation: :reaction_add,
                   target_provider_message_id: "1.1",
                   payload: %{"reaction_key" => "thumbs_up"}
               })
    end

    test "a replacement preview message is checkpointed even when its first source is immutable" do
      %{principal: agent} = agent_fixture()
      binding_name = "slack-preview-replacement"
      config_key = Config.chat_config_key(binding_name)
      assert {:ok, _} = AppConfigure.put_global_by_key(config_key, chat_config())

      assert {:ok, _} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: binding_name,
                 adapter: "slack",
                 config_ref: "app-config://" <> config_key,
                 unaddressed_group_message_policy: :ignore,
                 unmatched_sender_policy: :create_standalone
               })

      %{signal: event} =
        emit_addressed_signal(
          agent.uid,
          binding_name,
          group_entry(%{
            provider_conversation_id: "slack:C1",
            provider_message_id: "preview-input",
            provider_thread_id: nil,
            explicit: true
          })
        )

      parent = self()
      posts = start_supervised!({Agent, fn -> 0 end})

      Req.default_options(
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Torque.decode!(body)

          cond do
            String.ends_with?(conn.request_path, "/chat.postMessage") ->
              count = Agent.get_and_update(posts, fn n -> {n, n + 1} end)
              id = if count == 0, do: "preview-A", else: "preview-B"
              send(parent, {:preview_post, id})
              Req.Test.json(conn, %{"ok" => true, "ts" => id, "channel" => "C1"})

            String.ends_with?(conn.request_path, "/chat.update") ->
              send(parent, {:preview_update, body["ts"]})

              if body["ts"] == "preview-A" do
                Req.Test.json(conn, %{"ok" => false, "error" => "message_not_found"})
              else
                Req.Test.json(conn, %{"ok" => true, "ts" => body["ts"], "channel" => "C1"})
              end

            true ->
              flunk("unexpected Slack provider operation: #{conn.request_path}")
          end
        end
      )

      {:ok, adapter} = PreviewAdapter.from_module(SlackAdapter.ReplyPreview)

      request = %Request{
        signal: event,
        presentation: ReplyPresentation.new() |> ReplyPresentation.replace_answer("first"),
        mode: :working
      }

      assert {:ok, _} = PreviewAdapter.update(adapter, request)
      assert_receive {:preview_post, "preview-A"}

      changed = %{
        request
        | presentation: ReplyPresentation.replace_answer(request.presentation, "second")
      }

      assert {:error,
              {:reply_delivery, :operator_action_required, %{"code" => "slack_delivery_unknown"}}} =
               PreviewAdapter.update(adapter, changed)

      assert_receive {:preview_update, "preview-A"}
      assert_receive {:preview_post, "preview-B"}
      stored = Repo.get!(Signal, event.id)

      checkpoint =
        PreviewAdapter.adapter_checkpoint(
          Ankole.Conversations.Delivery.PreviewState.get(stored).checkpoint
        )

      assert hd(checkpoint["messages"])["message_id"] == "preview-B"

      assert Ankole.Conversations.Delivery.PreviewState.get(stored).provider_message_id ==
               "preview-A"

      changed = %{
        changed
        | presentation: ReplyPresentation.replace_answer(request.presentation, "third")
      }

      assert {:error,
              {:reply_delivery, :operator_action_required, %{"code" => "slack_delivery_unknown"}}} =
               PreviewAdapter.update(adapter, changed)

      assert_receive {:preview_update, "preview-B"}
      assert Agent.get(posts, & &1) == 2
      refute_receive {:preview_post, _}, 100
    end

    test "keeps every long reply chunk in the same Slack thread" do
      text = String.duplicate("a", 24_001)

      assert {:ok, requests} =
               Delivery.requests_for_intent(%Intent{
                 operation: :reply,
                 conversation_id: external_conversation_id("slack:C1"),
                 reply_to_provider_message_id: "1.1",
                 payload: %{},
                 fallback_visible_text: text
               })

      assert length(requests) == 3
      assert Enum.all?(requests, &(&1.body["thread_ts"] == "1.1"))
      assert Enum.all?(requests, &(&1.reply? == true))
    end

    test "a later chunk failure reports uncertain delivery after the first chunk was sent" do
      parent = self()
      %{principal: agent} = agent_fixture()
      binding_name = "slack-partial-send"

      assert {:ok, _} =
               AppConfigure.put_global_by_key(Config.chat_config_key(binding_name), chat_config())

      assert {:ok, _} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: binding_name,
                 adapter: "slack",
                 config_ref: "app-config://" <> Config.chat_config_key(binding_name),
                 unaddressed_group_message_policy: :ignore,
                 unmatched_sender_policy: :create_standalone
               })

      Req.default_options(
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          text = Torque.decode!(body)["text"]
          send(parent, {:sent_chunk, text})

          if String.starts_with?(text, "a") do
            Req.Test.json(conn, %{"ok" => true, "ts" => "1.1", "channel" => "C1"})
          else
            Req.Test.json(conn, %{"ok" => false, "error" => "channel_not_found"})
          end
        end
      )

      assert :unknown =
               Delivery.deliver(%Intent{
                 agent_uid: agent.uid,
                 binding_name: binding_name,
                 operation: :post,
                 conversation_id: external_conversation_id("slack:C1"),
                 payload: %{},
                 fallback_visible_text: String.duplicate("a", 12_000) <> "b"
               })

      assert_receive {:sent_chunk, first}
      assert String.length(first) == 12_000
      assert_receive {:sent_chunk, "b"}
      refute_received {:sent_chunk, _}
    end

    test "records an attachment before its Slack download starts" do
      parent = self()
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "slack", :record_only, adapter: "slack")
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      Req.default_options(
        plug: fn conn ->
          pending =
            Repo.get_by!(InboundBatch,
              agent_uid: agent.uid,
              binding_name: "slack",
              conversation_id: external_conversation_id("slack:C1"),
              batch_state: :open
            )

          send(parent, {:slack_pending_attachment, pending})
          Plug.Conn.send_resp(conn, 400, "download unavailable")
        end
      )

      incoming =
        event(%{
          "channel" => "C1",
          "channel_type" => "channel",
          "user" => "U1",
          "text" => "file",
          "ts" => "1700000000.009900",
          "files" => [
            %{
              "id" => "F99",
              "name" => "pending.pdf",
              "url_private" => "https://files.test/F99",
              "mimetype" => "application/pdf",
              "size" => 10
            }
          ]
        })

      assert {:ok, [%{status: :recorded, message_observation: observation}]} =
               Inbound.handle_message_receive("message", incoming, [consumer])

      assert_receive {:slack_pending_attachment, pending}

      assert get_in(List.first(pending.entries), [
               "metadata",
               "attachment_materialization",
               "state"
             ]) ==
               "pending"

      assert observation.external_ref.metadata["attachment_materialization"]["state"] == "failed"
      assert [%{"attachment_id" => attachment_id}] = observation.message.attachments
      assert attachment_id >= 10_000
    end

    test "a filtered attachment message succeeds without downloading or retrying" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "slack", :ignore, adapter: "slack", filters: %{"cel" => "false"})
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())
      Req.default_options(plug: fn _conn -> flunk("a filtered attachment must not download") end)

      incoming =
        event(%{
          "channel" => "C1",
          "channel_type" => "channel",
          "user" => "U1",
          "text" => "file",
          "ts" => "1700000000.001",
          "files" => [
            %{
              "id" => "F-filtered",
              "name" => "file.pdf",
              "url_private" => "https://media.test/filtered"
            }
          ]
        })

      assert {:ok, [%{status: :filtered}]} =
               Inbound.handle_message_receive("message", incoming, [consumer])

      refute Ankole.Conversations.External.get_conversation(Repo, "slack:C1")
    end

    test "Slack actions carry an authorized Principal identity" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "slack", :ignore, adapter: "slack")
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      action = %Event{
        id: "Ev-action-1",
        type: "block_actions",
        content: %{
          "user" => %{"id" => "U-ACTION"},
          "container" => %{"channel_id" => "C1", "message_ts" => "1.1"},
          "actions" => [
            %{
              "action_id" => "custom",
              "action_ts" => "2.2",
              "value" => Torque.encode!(%{"custom" => "value"})
            }
          ]
        },
        raw: %{}
      }

      assert {:ok, [%{status: :accepted, signal: signal}]} =
               Inbound.handle_block_action("block_actions", action, [consumer])

      assert {:ok, operator} =
               Ankole.Principals.resolve_platform_subject("slack-main", "U-ACTION")

      assert signal.data["action"]["operator_id"] == "U-ACTION"
      assert signal.data["action"]["operator_principal_uid"] == operator.uid
      assert signal.data["action"]["value"] == %{"custom" => "value"}
    end

    test "private-channel rename schedules a Slack channel refresh" do
      %{principal: agent} = agent_fixture()
      consumer = Inbound.chat_consumer(adapter_context(agent.uid), chat_config())

      rename = %Event{
        id: "Ev-group-rename-1",
        type: "group_rename",
        content: %{"channel" => %{"id" => "G1", "name" => "renamed-private"}},
        raw: %{}
      }

      assert {:ok, [%{status: :refresh_enqueued, job_id: job_id}]} =
               Channels.handle_im_event("group_rename", rename, [consumer])

      assert is_integer(job_id)
    end
  end

  describe "directory membership ownership" do
    test "full sync imports paginated humans, filters bots and deleted users, and replaces memberships" do
      assert {:ok, stale_group} =
               Ankole.IdentityProviders.Directory.ensure_group(
                 "slack-main",
                 %Ankole.IdentityProviders.Directory.Group{
                   external_id: "OLD",
                   kind: "usergroup",
                   display_name: "Old team"
                 }
               )

      assert {:ok, previous} =
               IdentityProvider.upsert_user("slack-main", %{"id" => "U2"},
                 group_external_ids: ["OLD"]
               )

      Req.Test.stub(__MODULE__, fn conn ->
        body =
          case {conn.request_path, URI.decode_query(conn.query_string)["cursor"]} do
            {"/api/usergroups.list", _} ->
              %{
                "ok" => true,
                "usergroups" => [%{"id" => "S1", "name" => "Engineering", "users" => ["U1"]}]
              }

            {"/api/users.list", nil} ->
              %{
                "ok" => true,
                "members" => [
                  %{"id" => "U1", "name" => "Ada"},
                  %{"id" => "BOT", "is_bot" => true},
                  %{"id" => "DELETED", "deleted" => true}
                ],
                "response_metadata" => %{"next_cursor" => "next-page"}
              }

            {"/api/users.list", "next-page"} ->
              %{"ok" => true, "members" => [%{"id" => "U2", "name" => "Grace"}]}
          end

        Req.Test.json(conn, body)
      end)

      Req.default_options(plug: {Req.Test, __MODULE__})

      assert {:ok, %{users: 2, usergroups: 1}} =
               IdentityProvider.sync_directory("slack-main", %{"botToken" => "xoxb-sync"})

      assert {:ok, uid} = Ankole.Principals.resolve_platform_subject_uid("slack-main", "U1")
      [group_id] = AuthZ.external_group_ids("slack-main", :directory_department, "S1")
      assert Repo.get_by(Membership, principal_uid: uid, group_id: group_id)

      refute Repo.get_by(Membership,
               principal_uid: previous.principal.uid,
               group_id: stale_group.id
             )

      for id <- ["BOT", "DELETED"] do
        assert {:error, :not_found} =
                 Ankole.Principals.resolve_platform_subject_uid("slack-main", id)
      end
    end

    test "missing group_external_ids preserves memberships while explicit empty clears them" do
      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "slack-main:usergroup:s1",
                 display_name: "Engineering",
                 domain: :directory
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "slack-main",
                 external_kind: :directory_department,
                 external_id: "S1",
                 group_id: group.id,
                 metadata: %{"kind" => "usergroup"}
               })

      user = %{"id" => "U1", "name" => "Ada", "profile" => %{"email" => "ada@example.com"}}

      assert {:ok, observed} =
               IdentityProvider.upsert_user("slack-main", user, group_external_ids: ["S1"])

      assert Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)

      assert {:ok, _observed} =
               IdentityProvider.upsert_user("slack-main", Map.put(user, "name", "Ada Updated"))

      assert Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)

      assert {:ok, _observed} =
               IdentityProvider.upsert_user("slack-main", user, group_external_ids: [])

      refute Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)
    end

    test "realtime usergroup events create, replace, delta-update, and disable memberships" do
      assert {:ok, u1} =
               IdentityProvider.upsert_user("slack-main", %{"id" => "U1", "name" => "Ada"})

      assert {:ok, u2} =
               IdentityProvider.upsert_user("slack-main", %{"id" => "U2", "name" => "Grace"})

      consumer =
        IdentityProvider.identity_consumer("slack-main", %{
          "botToken" => "xoxb-bot",
          "appToken" => "xapp-app"
        })

      created = %Event{
        id: "Ev-created",
        type: "subteam_created",
        content: %{
          "subteam" => %{
            "id" => "S1",
            "name" => "Engineering",
            "users" => [],
            "user_count" => 0
          }
        },
        raw: %{}
      }

      assert {:ok, [%{status: :usergroup_created, group_id: group_id}]} =
               IdentityProvider.handle_contact_event("subteam_created", created, [consumer])

      updated = %Event{
        id: "Ev-updated",
        type: "subteam_updated",
        content: %{
          "subteam" => %{
            "id" => "S1",
            "name" => "Engineering",
            "users" => ["U1"],
            "user_count" => 1,
            "date_delete" => 0
          }
        },
        raw: %{}
      }

      assert {:ok, [%{status: :usergroup_updated}]} =
               IdentityProvider.handle_contact_event("subteam_updated", updated, [consumer])

      assert Repo.get_by(Membership, principal_uid: u1.principal.uid, group_id: group_id)

      delta = %Event{
        id: "Ev-delta",
        type: "subteam_members_changed",
        content: %{
          "subteam_id" => "S1",
          "added_users" => ["U2"],
          "added_users_count" => 1,
          "removed_users" => ["U1"],
          "removed_users_count" => 1
        },
        raw: %{}
      }

      assert {:ok, [%{status: :usergroup_members_delta_applied, added: 1, removed: 1}]} =
               IdentityProvider.handle_contact_event("subteam_members_changed", delta, [consumer])

      refute Repo.get_by(Membership, principal_uid: u1.principal.uid, group_id: group_id)
      assert Repo.get_by(Membership, principal_uid: u2.principal.uid, group_id: group_id)

      disabled_content = put_in(updated.content, ["subteam", "date_delete"], 1)
      disabled = %{updated | id: "Ev-disabled", content: disabled_content}

      assert {:ok, [%{status: :usergroup_disabled}]} =
               IdentityProvider.handle_contact_event("subteam_updated", disabled, [consumer])

      refute Repo.get_by(Membership, principal_uid: u2.principal.uid, group_id: group_id)
    end
  end

  describe "connection reconciliation" do
    test "saving a binding requests an immediate connection reconcile" do
      %{principal: agent} = agent_fixture()
      binding_name = "slack-reconcile-saved"
      config = chat_config(%{"appToken" => "xapp-reconcile-saved", "botUserID" => "U0SAVED"})
      key = Config.connection_key(config)

      assert {:ok, _config} =
               AppConfigure.put_global_by_key(Config.chat_config_key(binding_name), config)

      assert {:ok, binding} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: binding_name,
                 adapter: "slack",
                 config_ref: "app-config://#{Config.chat_config_key(binding_name)}",
                 filters: %{},
                 unaddressed_group_message_policy: :ignore,
                 unmatched_sender_policy: :create_standalone
               })

      on_exit(fn -> ConnectionReconciler.stop(key) end)

      assert :ok = Channels.handle_binding_saved(binding, config)
      assert eventually(fn -> key in ConnectionReconciler.registered_keys() end)
    end

    test "a connection resolves shared bot identity once and keeps it across reconciliation" do
      parent = self()
      Req.Test.set_req_test_to_shared()

      Req.default_options(
        plug: fn conn ->
          case conn.request_path do
            "/api/auth.test" ->
              send(parent, :bot_identity_requested)
              Req.Test.json(conn, %{"ok" => true, "user_id" => "UBOT", "bot_id" => "B1"})

            "/api/bots.info" ->
              Req.Test.json(conn, %{"ok" => true, "bot" => %{"id" => "B1", "app_id" => "A1"}})

            _ ->
              Req.Test.json(conn, %{"ok" => false, "error" => "service_unavailable"})
          end
        end
      )

      config = chat_config(%{"appToken" => "xapp-identity-once"})

      consumers =
        Enum.map(["one", "two"], fn name ->
          context =
            AdapterContext.new(
              agent_uid: "slack-identity-agent",
              binding_name: name,
              adapter: "slack",
              user_name: "Slack"
            )

          Inbound.chat_consumer(context, config)
        end)

      key = Config.connection_key(config)
      on_exit(fn -> ConnectionReconciler.stop(key) end)
      assert {:ok, _pid} = start_connection_owner(ConnectionReconciler, config, consumers)
      assert_receive :bot_identity_requested

      assert owner_serves?(ConnectionReconciler, key, config, consumers)

      refute_receive :bot_identity_requested, 100
    end

    test "a rotated bot token restarts the owner under the same app token" do
      config = chat_config(%{"appToken" => "xapp-reconcile-rotate", "botUserID" => "UBOT"})
      key = Config.connection_key(config)

      context =
        AdapterContext.new(
          agent_uid: "slack-rotate-agent",
          binding_name: "slack-reconcile-rotate",
          adapter: "slack",
          user_name: "Slack"
        )

      assert {:ok, old_owner} =
               start_connection_owner(ConnectionReconciler, config, [
                 Inbound.chat_consumer(context, config)
               ])

      on_exit(fn -> ConnectionReconciler.stop(key) end)

      rotated = Map.put(config, "botToken", "xoxb-rotated")
      assert Config.connection_key(rotated) == key

      refute owner_serves?(ConnectionReconciler, key, rotated, [
               Inbound.chat_consumer(context, rotated)
             ])

      assert :ok = ConnectionReconciler.stop(key)

      assert {:ok, new_owner} =
               start_connection_owner(ConnectionReconciler, rotated, [
                 Inbound.chat_consumer(context, rotated)
               ])

      refute Process.alive?(old_owner)
      assert Process.alive?(new_owner)
      refute new_owner == old_owner
    end

    test "the reconciler stops the owner after its binding is disabled" do
      %{principal: agent} = agent_fixture()
      binding_name = "slack-reconcile-stop"
      config = chat_config(%{"appToken" => "xapp-reconcile-stop", "botUserID" => "U0STOP"})
      key = Config.connection_key(config)

      binding_fixture(agent.uid, binding_name, :ignore, adapter: "slack")

      context =
        AdapterContext.new(
          agent_uid: agent.uid,
          binding_name: binding_name,
          adapter: "slack",
          user_name: "Slack"
        )

      assert {:ok, owner} =
               start_connection_owner(ConnectionReconciler, config, [
                 Inbound.chat_consumer(context, config)
               ])

      on_exit(fn -> ConnectionReconciler.stop(key) end)

      assert {:ok, _binding} = Ankole.Signals.Bindings.disable_binding(agent.uid, binding_name)

      assert %{started: 0, stopped: 1, errors: []} = ConnectionReconciler.reconcile_once()
      refute Process.alive?(owner)
    end
  end

  defp chat_consumer(overrides) do
    context =
      AdapterContext.new(
        agent_uid: "agent-1",
        binding_name: "slack",
        adapter: "slack",
        user_name: "Slack"
      )

    Inbound.chat_consumer(context, Map.merge(chat_config(), overrides))
  end

  defp adapter_context(agent_uid) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: "slack",
      adapter: "slack",
      user_name: "Slack"
    )
  end

  defp stub_slack_download(%{request_path: "/api/auth.test"} = conn),
    do:
      Req.Test.json(conn, %{
        "ok" => true,
        "user_id" => "UBOT",
        "bot_id" => "B1",
        "team_id" => "T1"
      })

  defp stub_slack_download(%{request_path: "/api/bots.info"} = conn),
    do: Req.Test.json(conn, %{"ok" => true, "bot" => %{"id" => "B1", "app_id" => "A1"}})

  defp stub_slack_download(%{request_path: "/api/apps.connections.open"} = conn),
    do: Req.Test.json(conn, %{"ok" => false, "error" => "service_unavailable"})

  defp stub_slack_download(conn) do
    conn
    |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="a.txt"))
    |> Plug.Conn.send_resp(200, "abc")
  end

  defp chat_config(overrides \\ %{}) do
    Map.merge(
      %{
        "botToken" => "xoxb-bot",
        "appToken" => "xapp-app",
        "userName" => "Slack"
      },
      overrides
    )
  end

  defp event(content) do
    %Event{
      id: "Ev1",
      type: "message",
      content: content,
      team_id: "T1",
      api_app_id: "A1",
      created_at: ~U[2026-07-11 00:00:00Z],
      raw: %{"envelope_id" => "env-1"}
    }
  end
end
