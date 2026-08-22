defmodule Ankole.Plugins.SlackAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.Plugins.SlackAdapter

  alias Ankole.Plugins.SlackAdapter.{
    BlockKit,
    Channels,
    Config,
    ConnectionReconciler,
    ConnectionSupervisor,
    Dispatcher,
    Emoji,
    ErrorPolicy,
    IdentityProvider,
    Inbound,
    Mrkdwn,
    Outbox
  }

  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{AdapterContext, InboundBatch, OutboxEntry}
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
      dispatcher = Dispatcher.build([])

      envelope =
        {:envelope,
         %{
           "type" => "events_api",
           "payload" => %{"event" => %{"type" => "app_mention"}}
         }}

      assert "app_mention" in Dispatcher.event_types()
      assert "group_rename" in Dispatcher.event_types()
      assert {:ok, []} = SocketDispatcher.dispatch(dispatcher, envelope)
    end

    test "declares chat and identity contracts" do
      assert SlackAdapter.plugin_id() == "slack-adapter"

      assert [
               %{contract_id: "signals_gateway.adapter", id: "slack", config_module: Config},
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
      assert config["platformSubjectNamespace"] == "slack-main"
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

    test "runtime bot identity uses auth.test result without persisting it" do
      {:ok, config} = Config.validate_chat_config(chat_config())

      Req.default_options(
        plug: fn conn ->
          assert conn.request_path == "/api/auth.test"

          Req.Test.json(conn, %{
            "ok" => true,
            "user_id" => "UBOT",
            "bot_id" => "B1",
            "team_id" => "T1"
          })
        end
      )

      resolved = Config.resolve_runtime_bot_identity(config)

      assert resolved["runtimeBotUserID"] == "UBOT"
      assert resolved["runtimeBotID"] == "B1"
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
            "source_actor_event_id" => "019fbd9e-5800-7000-8000-000000000001",
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
               "sourceActorEventId" => "019fbd9e-5800-7000-8000-000000000001"
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
      assert :ok =
               Ankole.I18n.with_locale("zh-Hans-CN", fn ->
                 assert {:ok, blocks} =
                          BlockKit.render(%{
                            "reply_presentation" => %{
                              "state" => "debouncing",
                              "answer" => ""
                            }
                          })

                 rendered = Torque.encode!(blocks)
                 assert rendered =~ "正在接收请求"
                 refute rendered =~ "Starting"
                 :ok
               end)
    end

    test "emoji mapping strips skin tone and round-trips stable keys" do
      assert Emoji.normalize("thumbsup::skin-tone-3") == "thumbs_up"
      assert Emoji.normalize("custom") == "custom"
      assert Emoji.provider_key("thumbs_up") == "thumbsup"
    end
  end

  describe "inbound and outbox normalization" do
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
      assert normalized.signal_channel_id == "slack:C1"
      assert normalized.provider_thread_id == "slack:C1:1699999999.000001"
      assert normalized.reply_to_source_entry_id == "1699999999.000001"
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
      assert is_nil(normalized.reply_to_source_entry_id)

      root_event = %{event | content: Map.put(event.content, "thread_ts", "1700000000.000200")}

      assert {:ok, root} = Inbound.normalize_message_receive(root_event, consumer)
      assert is_nil(root.provider_thread_id)
      assert is_nil(root.reply_to_source_entry_id)
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

    test "builds every Slack outbox request shape" do
      base = %OutboxEntry{
        signal_channel_id: "slack:C1",
        payload: %{},
        fallback_visible_text: "**hello**"
      }

      assert {:ok,
              [%{method: "chat.postMessage", body: %{"channel" => "C1", "text" => "*hello*"}}]} =
               Outbox.requests_for_outbox(%{base | operation: :post})

      assert {:ok, [%{body: %{"thread_ts" => "1.1"}}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :reply,
                   reply_to_source_entry_id: "1.1"
               })

      assert {:ok, [%{method: "chat.update"}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :edit,
                   target_source_entry_id: "1.1"
               })

      assert {:ok, [%{method: "reactions.add", body: %{"name" => "thumbsup"}}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :reaction_add,
                   target_source_entry_id: "1.1",
                   payload: %{"reaction_key" => "thumbs_up"}
               })
    end

    test "keeps every long reply chunk in the same Slack thread" do
      text = String.duplicate("a", 24_001)

      assert {:ok, requests} =
               Outbox.requests_for_outbox(%OutboxEntry{
                 operation: :reply,
                 signal_channel_id: "slack:C1",
                 reply_to_source_entry_id: "1.1",
                 payload: %{},
                 fallback_visible_text: text
               })

      assert length(requests) == 3
      assert Enum.all?(requests, &(&1.body["thread_ts"] == "1.1"))
      assert Enum.all?(requests, &(&1.reply? == true))
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
              signal_channel_id: "slack:C1",
              batch_state: "open"
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

      assert {:ok, [%{status: :recorded, signal_entry: entry}]} =
               Inbound.handle_message_receive("message", incoming, [consumer])

      assert_receive {:slack_pending_attachment, pending}

      assert get_in(List.first(pending.entries), [
               "metadata",
               "attachment_materialization",
               "state"
             ]) ==
               "pending"

      assert entry.metadata["attachment_materialization"]["state"] == "failed"
      assert [%{"attachment_id" => attachment_id}] = entry.attachments
      assert attachment_id >= 10_000
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

      assert {:ok, [%{status: :accepted, actor_event: actor_event}]} =
               Inbound.handle_block_action("block_actions", action, [consumer])

      assert {:ok, operator} =
               Ankole.Principals.resolve_platform_subject("slack-main", "U-ACTION")

      assert actor_event.payload["data"]["action"]["operator_id"] == "U-ACTION"
      assert actor_event.payload["data"]["action"]["operator_principal_uid"] == operator.uid
      assert actor_event.payload["data"]["action"]["value"] == %{"custom" => "value"}
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
    test "a rotated bot token restarts the owner under the same app token" do
      config = chat_config(%{"appToken" => "xapp-reconcile-rotate"})
      key = Config.connection_key(config)

      context =
        AdapterContext.new(
          agent_uid: "slack-rotate-agent",
          binding_name: "slack-reconcile-rotate",
          adapter: "slack",
          user_name: "Slack"
        )

      assert {:ok, old_owner} =
               ConnectionSupervisor.ensure_started(config, [
                 Inbound.chat_consumer(context, config)
               ])

      on_exit(fn -> ConnectionSupervisor.stop(key) end)

      rotated = Map.put(config, "botToken", "xoxb-rotated")
      assert Config.connection_key(rotated) == key

      assert {:ok, new_owner} =
               ConnectionSupervisor.ensure_started(rotated, [
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
               ConnectionSupervisor.ensure_started(config, [
                 Inbound.chat_consumer(context, config)
               ])

      on_exit(fn -> ConnectionSupervisor.stop(key) end)

      assert {:ok, _binding} = SignalsGateway.disable_binding(agent.uid, binding_name)

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
        "platformSubjectNamespace" => "slack-main",
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
