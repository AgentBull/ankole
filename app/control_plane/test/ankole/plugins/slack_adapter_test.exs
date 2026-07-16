defmodule Ankole.Plugins.SlackAdapterTest do
  use Ankole.DataCase, async: false

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.Plugins.SlackAdapter

  alias Ankole.Plugins.SlackAdapter.{
    BlockKit,
    Config,
    ConnectionOwner,
    ConnectionSupervisor,
    Emoji,
    IdentityProvider,
    Inbound,
    Mrkdwn,
    Outbox
  }

  alias Ankole.Repo
  alias Ankole.SignalsGateway.{AdapterContext, OutboxEntry}
  alias SlackOpenAPI.Event

  describe "plugin and config contracts" do
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

      resolved =
        Config.resolve_runtime_bot_identity(config,
          bot_info_fetcher: fn _config ->
            {:ok, %{"user_id" => "UBOT", "bot_id" => "B1", "team_id" => "T1"}}
          end
        )

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

    test "emoji mapping strips skin tone and round-trips stable keys" do
      assert Emoji.normalize("thumbsup::skin-tone-3") == "thumbs_up"
      assert Emoji.normalize("custom") == "custom"
      assert Emoji.provider_key("thumbs_up") == "thumbsup"
    end
  end

  describe "connection ownership" do
    test "one app-token fingerprint owns one connection and bot-token conflicts are rejected" do
      registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
      supervisor = Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

      consumer = chat_consumer(%{"runtimeBotUserID" => "UBOT"})
      config = consumer.config

      assert {:ok, pid} =
               ConnectionSupervisor.ensure_started(config, [consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert {:ok, ^pid} =
               ConnectionSupervisor.ensure_started(config, [consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert {:error, :conflicting_app_secret} =
               ConnectionSupervisor.ensure_started(
                 %{config | "botToken" => "xoxb-conflict"},
                 [consumer],
                 registry: registry,
                 supervisor: supervisor,
                 start_client?: false
               )

      assert %{consumer_count: 1, consumer_kinds: [:chat], running?: false} =
               ConnectionOwner.status(pid)
    end
  end

  describe "inbound and outbox normalization" do
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
  end

  describe "directory membership ownership" do
    test "missing usergroup_ids preserves memberships while explicit empty clears them" do
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
               IdentityProvider.upsert_user("slack-main", user, usergroup_ids: ["S1"])

      assert Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)

      assert {:ok, _observed} =
               IdentityProvider.upsert_user("slack-main", Map.put(user, "name", "Ada Updated"))

      assert Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)

      assert {:ok, _observed} =
               IdentityProvider.upsert_user("slack-main", user, usergroup_ids: [])

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
