defmodule Ankole.Plugins.Microsoft365AdapterTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.Plugins.Microsoft365Adapter

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.IdentityProviders

  alias Ankole.Plugins.Microsoft365Adapter.{
    AdaptiveCard,
    BotFrameworkAuth,
    Config,
    Conversations,
    DirectoryWebhook,
    Emoji,
    GraphSubscriptions,
    IdentityProvider,
    Inbound,
    Markdown,
    Outbox,
    SubscriptionReconciler,
    TeamsChannels,
    TeamsWebhook
  }

  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{AdapterContext, BindingMembership, Channel, OutboxEntry}

  @app_id "11111111-2222-3333-4444-555555555555"
  @app_id_b "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  @tenant_id "99999999-8888-7777-6666-555555555555"
  @service_url "https://smba.trafficmanager.net/teams/"

  # RS256 token from the kernel test fixture: kid test-key-1, iss
  # api.botframework.com, aud @app_id, serviceUrl @service_url, exp 2100-01-01.
  @rs256_token "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2V5LTEifQ.eyJpc3MiOiJodHRwczovL2FwaS5ib3RmcmFtZXdvcmsuY29tIiwiYXVkIjoiMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1Iiwic2VydmljZVVybCI6Imh0dHBzOi8vc21iYS50cmFmZmljbWFuYWdlci5uZXQvdGVhbXMvIiwiZXhwIjo0MTAyNDQ0ODAwfQ.ZIR18QFxalBM4yQuG2cH1M30wm3gYEdPeQyjxiJMe008iJ-r2-bE8HUMmhlZHqdnUMpH8YvKfKz_M4yCVuDD6oNJXBBZHHN6PGW5peuaE5yRf9u6o0R1xArV-LTxkW3te2RgHSEbvaQrUUozASQbbP5UjpCzpB172Q5V2tyc2YvXsjZug0gRAtY3DdONrijJm4wxusyYT4Yaf2b_wJSKQJ-g6vlzq5LENdWCWP-cq_aHRdnWcmsMepH3oE2z0g38YDlumNN9gZV6L3JQpUFnKv_e46jIAnixV-Dl1ZXoSdnB7psVACgnaVkn4FtB5ToEms3UuYyPfIaYPlQpXm-JJg"
  @jwk_n "voAhnbPZoyk16UJ5MBXNX08cXYR3u2AQVCX_ryzDEtKUy-PUzk29MSf32f0AdYjdCqaTva8Xc8Vg77DeBzNVGiDxKZgY2Pp3r4e02vZHSkIF5aWXfOzrc-ZHsJqhOmf1hRE9LjAo6Zwe48ZyeH9MaKF0BbV5yU8WW3ed0OglCgRTxO1oigIeRwrXriZ0IDnBHakY0XpXAcRCBHfCqA7ISLEs8qA-vABhlQZ0G2kaqGJ8h1C4xoB2qasiKqGu8z7_3RyH2M14UUSXG_pJcqnXu4XzQLW5icWsaTgMHQe7ki_u2FfVdQKsdDbYBpHn0pk_r1raFmEs3mDAT4xAvRZThQ"

  setup do
    Req.Test.set_req_test_to_shared()
    # Earlier suites in the same run may clear the global AppConfigure
    # registries, so config-key writes re-register this plugin's patterns.
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    previous = Req.default_options()
    Req.Test.stub(__MODULE__, &default_microsoft_request/1)
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
  end

  describe "plugin and config contracts" do
    test "declares chat, identity, and webhook contracts" do
      assert Microsoft365Adapter.plugin_id() == "microsoft365-adapter"

      assert [
               %{
                 contract_id: "signals_gateway.adapter",
                 id: "teams",
                 config_module: Config,
                 binding_saved_module: TeamsChannels
               },
               %{
                 contract_id: "signals_gateway.webhook_handler",
                 id: "teams",
                 module: TeamsWebhook,
                 kinds: ["messages"]
               },
               %{
                 contract_id: "principals.identity_provider",
                 id: "entra-id",
                 module: IdentityProvider,
                 connection_reconciler: SubscriptionReconciler
               },
               %{
                 contract_id: "signals_gateway.webhook_handler",
                 id: "entra-id",
                 module: DirectoryWebhook,
                 kinds: ["directory"]
               }
             ] = Microsoft365Adapter.adapter_declarations()

      declarations = Microsoft365Adapter.adapter_declarations()
      chat = Enum.find(declarations, &(&1.contract_id == "signals_gateway.adapter"))

      refute "add_reaction" in chat.outbound_capabilities
      refute "outbound_reconciliation" in chat.outbound_capabilities
      assert Enum.all?(Microsoft365Adapter.app_config_patterns(), & &1.encrypted)

      identity = Enum.find(declarations, &(&1.contract_id == "principals.identity_provider"))
      fields = Map.new(identity.fields, &{&1.path, &1})

      assert fields["tenantID"].validation.pattern ==
               "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

      assert fields["publicBaseURL"].requiredWhen == [
               %{path: "sync.contacts", value: true},
               %{path: "sync.realtime", value: true}
             ]
    end

    test "chat validation enforces GUIDs and tenancy" do
      assert {:error, {:invalid_guid, "appID"}} =
               Config.validate_chat_config(%{"appID" => "not-a-guid", "appPassword" => "pw"})

      assert {:error, {:missing, "tenantID"}} =
               Config.validate_chat_config(%{"appID" => @app_id, "appPassword" => "pw"})

      assert {:ok, config} = Config.validate_chat_config(chat_config())
      assert config["platformSubjectNamespace"] == "entra-id-main"
      assert Config.bot_token_tenant(config) == @tenant_id

      assert {:ok, multi} =
               Config.validate_chat_config(%{
                 "appID" => @app_id,
                 "appPassword" => "pw",
                 "botTenancy" => "multi_tenant"
               })

      assert Config.bot_token_tenant(multi) == "botframework.com"
    end

    test "identity validation gates realtime on contacts and public base URL" do
      assert {:error, {:missing, "publicBaseURL"}} =
               Config.validate_identity_config(%{
                 "tenantID" => @tenant_id,
                 "clientID" => "client-1",
                 "clientSecret" => "secret-1"
               })

      assert {:ok, config} =
               Config.validate_identity_config(%{
                 "tenantID" => @tenant_id,
                 "clientID" => "client-1",
                 "clientSecret" => "secret-1",
                 "publicBaseURL" => "https://ankole.example.com"
               })

      assert config["sync"]["realtime"] == true
      assert config["oidc"]["scopes"] == ["openid", "profile", "email", "User.Read"]

      assert {:ok, no_contacts} =
               Config.validate_identity_config(%{
                 "tenantID" => @tenant_id,
                 "clientID" => "client-1",
                 "clientSecret" => "secret-1",
                 "sync" => %{"contacts" => false, "realtime" => true}
               })

      assert no_contacts["sync"]["realtime"] == false
    end

    test "subscription state accepts only complete machine entries" do
      assert {:ok, %{"subscriptions" => [_entry]} = state} =
               Config.validate_subscription_state(%{
                 "subscriptions" => [
                   %{
                     "id" => "sub-1",
                     "resource" => "/users",
                     "expiration" => "2026-07-15T00:00:00Z",
                     "clientState" => "secret"
                   }
                 ],
                 "updatedAt" => "2026-07-15T00:00:00Z"
               })

      refute Map.has_key?(state, "updatedAt")

      assert {:error, :invalid_graph_subscription_state} =
               Config.validate_subscription_state(%{"subscriptions" => [%{"id" => "sub-1"}]})
    end
  end

  describe "pure provider rendering" do
    test "markdown keeps commonmark and rewrites tables and rules" do
      input = "**bold** stays\n| a | b |\n| - | - |\n| 1 | 2 |\n---\n`code`"
      output = Markdown.from_markdown(input)

      assert output =~ "**bold** stays"
      assert output =~ "a · b"
      assert output =~ "1 · 2"
      assert output =~ "———"
      refute output =~ "| - |"
    end

    test "adaptive card renders interactive output with submit envelopes" do
      payload = %{
        "interactive_output" => %{
          "title" => "Decision",
          "body" => "**Choose**",
          "facts" => [%{"label" => "Owner", "value" => "Ada"}],
          "choices" => [%{"label" => "Approve", "value" => "yes"}],
          "state" => "Waiting"
        }
      }

      assert {:ok, card} = AdaptiveCard.render(payload)
      assert card["type"] == "AdaptiveCard"

      assert [%{"text" => "Decision"}, %{"text" => "**Choose**"}, %{"type" => "FactSet"}, _state] =
               card["body"]

      assert [
               %{
                 "type" => "Action.Submit",
                 "data" => %{"v" => "ankole.interactive_output.action.v1", "value" => "yes"}
               }
             ] = card["actions"]

      native = %{"teams_native_card" => %{"type" => "AdaptiveCard", "body" => []}}
      assert {:ok, %{"body" => []}} = AdaptiveCard.render(native)
      assert {:error, :missing_card_payload} = AdaptiveCard.render(%{})
    end

    test "reaction keys normalize into the shared vocabulary" do
      assert Emoji.normalize("like") == "thumbs_up"
      assert Emoji.normalize("Heart") == "heart"
      assert Emoji.normalize("custom-emoji") == "custom-emoji"
    end
  end

  describe "conversation algebra" do
    test "splits channel thread ids and round-trips signal ids" do
      thread_id = "19:room@thread.tacv2;messageid=1690000000001"

      assert Conversations.base_conversation_id(thread_id) == "19:room@thread.tacv2"
      assert Conversations.thread_root(thread_id) == "1690000000001"
      assert Conversations.thread_root("19:room@thread.tacv2") == nil

      signal = Conversations.signal_channel_id("19:room@thread.tacv2")
      assert signal == "teams:19%3Aroom%40thread.tacv2"
      assert Conversations.conversation_id_from_signal(signal) == "19:room@thread.tacv2"

      provider_thread =
        Conversations.provider_thread_id("19:room@thread.tacv2", "1690000000001")

      assert Conversations.thread_root_from_provider_thread_id(
               provider_thread,
               "19:room@thread.tacv2"
             ) == "1690000000001"
    end
  end

  describe "inbound normalization" do
    test "normalizes channel mention, thread, and file attachments" do
      consumer = chat_consumer()

      activity =
        message_activity(%{
          "conversation" => %{
            "id" => "19:room@thread.tacv2;messageid=1690000000001",
            "conversationType" => "channel"
          },
          "text" => "<at>Ankole</at> review <at>Ada</at> please",
          "entities" => [
            %{
              "type" => "mention",
              "text" => "<at>Ankole</at>",
              "mentioned" => %{"id" => "28:bot-app", "name" => "Ankole"}
            },
            %{
              "type" => "mention",
              "text" => "<at>Ada</at>",
              "mentioned" => %{"id" => "29:ada", "aadObjectId" => "oid-ada", "name" => "Ada"}
            }
          ],
          "attachments" => [
            %{
              "contentType" => "application/vnd.microsoft.teams.file.download.info",
              "name" => "report.xlsx",
              "content" => %{
                "downloadUrl" => "https://download.test/report.xlsx",
                "uniqueId" => "file-1",
                "fileType" => "xlsx"
              }
            },
            %{"contentType" => "text/html", "content" => "<p>ignored</p>"}
          ]
        })

      assert {:ok, normalized} = Inbound.normalize_message_receive(activity, consumer)

      assert normalized.signal_channel_id == "teams:19%3Aroom%40thread.tacv2"
      assert normalized.provider_thread_id =~ ":1690000000001"
      assert normalized.reply_to_source_entry_id == "1690000000001"
      assert normalized.explicit == true
      assert normalized.text == "review @Ada please"
      assert normalized.author["id"] == "oid-user"
      assert normalized.author["platform_subject"] == "oid-user"
      assert normalized.channel.metadata["service_url"] == @service_url
      assert normalized.channel.metadata["conversation_type"] == "channel"
      assert normalized.channel.metadata["team_id"] == "team-1"

      assert [%{"provider_ref" => "teams:file:file-1", "download_auth" => "none"}] =
               normalized.attachments

      assert [%{"targets_current_agent" => true}, %{"user_id" => "oid-ada"}] =
               normalized.mentions
    end

    test "personal messages are explicit DMs and bots are ignored" do
      consumer = chat_consumer()

      personal =
        message_activity(%{
          "conversation" => %{"id" => "a:1personal", "conversationType" => "personal"},
          "text" => "hello"
        })

      assert {:ok, normalized} = Inbound.normalize_message_receive(personal, consumer)
      assert normalized.explicit == true
      assert normalized.channel.kind == :im_dm
      assert is_nil(normalized.provider_thread_id)
      assert is_nil(normalized.reply_to_source_entry_id)

      bot_sender =
        message_activity(%{
          "from" => %{"id" => "28:other-bot", "name" => "Other Bot"},
          "text" => "bot noise"
        })

      assert {:ignore, :provider_self_sender} =
               Inbound.normalize_message_receive(bot_sender, consumer)

      no_aad =
        message_activity(%{
          "from" => %{"id" => "29:guest", "name" => "Guest"},
          "text" => "fallback id"
        })

      assert {:ok, fallback} = Inbound.normalize_message_receive(no_aad, consumer)
      assert fallback.author["id"] == "29:guest"
    end

    test "prefers the exact Bot Framework reply target over the channel thread root" do
      consumer = chat_consumer()

      activity =
        message_activity(%{
          "id" => "activity-reply",
          "replyToId" => "activity-parent",
          "text" => "compare this"
        })

      assert {:ok, normalized} = Inbound.normalize_message_receive(activity, consumer)
      assert normalized.reply_to_source_entry_id == "activity-parent"
      assert normalized.provider_thread_id =~ ":1690000000001"
    end
  end

  describe "bot framework auth" do
    test "verifies connector tokens and rejects mismatches" do
      stub_bot_openid!()

      headers = %{"authorization" => "Bearer " <> @rs256_token}
      activity = %{"serviceUrl" => @service_url}

      assert {:ok, claims} = BotFrameworkAuth.verify(headers, @app_id, activity)
      assert claims["iss"] == "https://api.botframework.com"

      assert {:error, :audience_mismatch} =
               BotFrameworkAuth.verify(headers, @tenant_id, activity)

      assert {:error, :service_url_mismatch} =
               BotFrameworkAuth.verify(
                 headers,
                 @app_id,
                 %{"serviceUrl" => "https://evil.example.com/"}
               )

      assert {:error, :missing_bearer_token} =
               BotFrameworkAuth.verify(%{}, @app_id, activity)
    end
  end

  describe "outbox request shapes" do
    test "maps post, reply, edit, delete, divider, and card operations" do
      channel_target = %{
        conversation_id: "19:room@thread.tacv2",
        service_url: @service_url,
        channel?: true
      }

      base = %OutboxEntry{
        signal_channel_id: "teams:19%3Aroom%40thread.tacv2",
        payload: %{},
        fallback_visible_text: "**hello**"
      }

      assert {:ok, [%{kind: :post, conversation_id: "19:room@thread.tacv2", activity: activity}]} =
               Outbox.requests_for_outbox(%{base | operation: :post}, channel_target)

      assert activity["textFormat"] == "markdown"
      assert activity["text"] == "**hello**"

      assert {:ok, [%{conversation_id: "19:room@thread.tacv2;messageid=root-1"}]} =
               Outbox.requests_for_outbox(
                 %{base | operation: :reply, reply_to_source_entry_id: "root-1"},
                 channel_target
               )

      chat_target = %{channel_target | channel?: false}

      assert {:ok, [%{conversation_id: "19:room@thread.tacv2"}]} =
               Outbox.requests_for_outbox(
                 %{base | operation: :reply, reply_to_source_entry_id: "root-1"},
                 chat_target
               )

      assert {:ok, [%{kind: :update, conversation_id: "19:room@thread.tacv2;messageid=root-1"}]} =
               Outbox.requests_for_outbox(
                 %{
                   base
                   | operation: :edit,
                     target_source_entry_id: "act-1",
                     provider_thread_id:
                       Conversations.provider_thread_id("19:room@thread.tacv2", "root-1")
                 },
                 channel_target
               )

      assert {:ok, [%{kind: :delete, idempotent_errors: errors}]} =
               Outbox.requests_for_outbox(
                 %{base | operation: :delete, target_source_entry_id: "act-1"},
                 channel_target
               )

      assert "ActivityNotFoundInConversation" in errors

      assert {:ok, [%{activity: divider}]} =
               Outbox.requests_for_outbox(%{base | operation: :divider}, channel_target)

      assert divider["text"] =~ "———"

      card_entry = %{
        base
        | operation: :card,
          payload: %{"interactive_output" => %{"title" => "T", "body" => "B"}}
      }

      assert {:ok, [%{activity: card_activity}]} =
               Outbox.requests_for_outbox(card_entry, channel_target)

      assert [%{"contentType" => "application/vnd.microsoft.card.adaptive"}] =
               card_activity["attachments"]
    end

    test "delivery target requires a mirrored serviceUrl and attachments are rejected" do
      {:ok, _channel} =
        TeamsChannels.upsert_channel_projection(
          %{
            conversation_id: "19:room@thread.tacv2",
            conversation_type: "channel",
            service_url: "https://smba.microsoft.test/teams/",
            team_id: "team-1",
            name: "Ops"
          },
          nil
        )

      outbox = %OutboxEntry{
        operation: :post,
        signal_channel_id: Conversations.signal_channel_id("19:room@thread.tacv2"),
        payload: %{},
        fallback_visible_text: "hello"
      }

      assert {:ok,
              %{
                conversation_id: "19:room@thread.tacv2",
                service_url: "https://smba.microsoft.test/teams/",
                channel?: true
              }} = Outbox.delivery_target(outbox)

      missing_mirror = %{
        outbox
        | signal_channel_id: Conversations.signal_channel_id("19:unknown@thread.tacv2")
      }

      assert {:error, :missing_channel_mirror} = Outbox.delivery_target(missing_mirror)

      with_attachment = %{outbox | payload: %{"attachments" => [%{"name" => "a.txt"}]}}
      assert {:error, :outbound_attachments_not_supported} = Outbox.send(with_attachment)
    end

    test "a later chunk failure preserves uncertainty about earlier delivery" do
      %{principal: agent} = agent_fixture()
      binding = teams_binding_fixture(agent.uid, "teams-send-partial")

      {:ok, _} =
        TeamsChannels.upsert_channel_projection(
          %{
            conversation_id: "partial-send",
            conversation_type: "personal",
            service_url: @service_url
          },
          nil
        )

      counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/token") ->
            Req.Test.json(conn, %{
              "access_token" => "bot-token",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            })

          String.contains?(conn.request_path, "/activities") ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1 do
              Req.Test.json(conn, %{"id" => "activity-1"})
            else
              conn
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(%{"error" => %{"code" => "BadArgument", "message" => "rejected"}})
            end

          true ->
            default_microsoft_request(conn)
        end
      end)

      assert :unknown =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: binding.name,
                 operation: :post,
                 signal_channel_id: Conversations.signal_channel_id("partial-send"),
                 payload: %{},
                 fallback_visible_text: String.duplicate("a", 24_001)
               })

      assert :counters.get(counter, 1) == 2
    end

    test "delivery failures classify for the gateway retry policy" do
      rate_limited = %MicrosoftOpenAPI.Error{reason: :rate_limited, status: 429, retry_after: 7}

      assert {:error, {:reply_delivery, :retryable, detail}} =
               Outbox.normalize_delivery_result({:error, rate_limited})

      assert detail.retry_after_seconds == 7

      auth = %MicrosoftOpenAPI.Error{reason: "InvalidAuthenticationToken", status: 401}

      assert {:error, {:reply_delivery, :operator_action_required, %{http_status: 401}}} =
               Outbox.normalize_delivery_result({:error, auth})

      gone = %MicrosoftOpenAPI.Error{reason: "ConversationNotFound", status: 404}

      assert {:error, {:reply_delivery, :permanent, %{reason: "ConversationNotFound"}}} =
               Outbox.normalize_delivery_result({:error, gone})
    end
  end

  describe "Teams channel membership projection" do
    test "one bot binding can leave without revoking another binding's visibility" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()
      first_binding_name = "teams-membership-a"
      second_binding_name = "teams-membership-b"
      teams_binding_fixture(first_agent.uid, first_binding_name)
      teams_binding_fixture(second_agent.uid, second_binding_name)
      conversation_id = "19:membership@thread.tacv2"

      assert {:ok, _channel} =
               TeamsChannels.upsert_channel_projection(
                 %{
                   conversation_id: conversation_id,
                   conversation_type: "channel",
                   service_url: @service_url,
                   team_id: "team-membership",
                   name: "Membership"
                 },
                 nil
               )

      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "bot-token", "expires_in" => 3600})
        else
          assert String.ends_with?(conn.request_path, "/pagedmembers")
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bot-token"]

          Req.Test.json(conn, %{
            "members" => [
              %{"id" => "29:user", "aadObjectId" => "oid-membership", "name" => "Ada"},
              %{"id" => "28:bot-app", "name" => "Ankole"}
            ]
          })
        end
      end)

      assert {:ok, %{group_id: group_id}} =
               TeamsChannels.refresh_conversation(
                 first_agent.uid,
                 first_binding_name,
                 conversation_id
               )

      assert {:ok, %{group_id: ^group_id}} =
               TeamsChannels.refresh_conversation(
                 second_agent.uid,
                 second_binding_name,
                 conversation_id
               )

      group = Repo.get!(Group, group_id)
      assert BindingMembership.joined?(group.metadata, first_agent.uid, first_binding_name)
      assert BindingMembership.joined?(group.metadata, second_agent.uid, second_binding_name)

      first_context =
        AdapterContext.new(
          agent_uid: first_agent.uid,
          binding_name: first_binding_name,
          adapter: "teams",
          user_name: "Teams"
        )

      second_context =
        AdapterContext.new(
          agent_uid: second_agent.uid,
          binding_name: second_binding_name,
          adapter: "teams",
          user_name: "Teams"
        )

      removed = %{
        "type" => "conversationUpdate",
        "conversation" => %{"id" => conversation_id, "conversationType" => "channel"},
        "recipient" => %{"id" => "28:bot-app"},
        "membersRemoved" => [%{"id" => "28:bot-app"}]
      }

      assert {:ok, %{status: :participant_marked_left}} =
               TeamsChannels.handle_conversation_update(
                 Inbound.chat_consumer(first_context, validated_chat_config()),
                 removed
               )

      group = Repo.get!(Group, group_id)
      refute BindingMembership.joined?(group.metadata, first_agent.uid, first_binding_name)
      assert BindingMembership.joined?(group.metadata, second_agent.uid, second_binding_name)

      assert {:ok, %{status: :all_participants_left}} =
               TeamsChannels.handle_conversation_update(
                 Inbound.chat_consumer(second_context, validated_chat_config()),
                 removed
               )

      group = Repo.get!(Group, group_id)
      refute BindingMembership.joined?(group.metadata, second_agent.uid, second_binding_name)
    end
  end

  describe "Teams mirror app sharding" do
    test "each binding's full sync only visits its own app's mirrors" do
      parent = self()
      %{principal: agent_a} = agent_fixture()
      %{principal: agent_b} = agent_fixture()
      teams_binding_fixture(agent_a.uid, "teams-shard-a")

      teams_binding_fixture(
        agent_b.uid,
        "teams-shard-b",
        Map.put(chat_config(), "appID", @app_id_b)
      )

      seed_mirror(%{
        conversation_id: "19:team-shard-a-general@thread.tacv2",
        team_id: "team-shard-a",
        app_id: @app_id
      })

      seed_mirror(%{
        conversation_id: "19:team-shard-b-general@thread.tacv2",
        team_id: "team-shard-b",
        app_id: @app_id_b
      })

      seed_mirror(%{
        conversation_id: "19:gchat-a@unq.gbl.spaces",
        conversation_type: "groupChat",
        app_id: @app_id
      })

      seed_mirror(%{
        conversation_id: "19:gchat-b@unq.gbl.spaces",
        conversation_type: "groupChat",
        app_id: @app_id_b
      })

      stub_team_sync(parent, %{})

      assert {:ok, %{synced_team_channels: 1, synced_group_chats: 1}} =
               TeamsChannels.sync_binding(agent_a.uid, "teams-shard-a")

      assert_received {:listed_team, "team-shard-a"}
      refute_received {:listed_team, _other_team}
      assert_received {:listed_members, "19:team-shard-a-general@thread.tacv2"}
      assert_received {:listed_members, "19:gchat-a@unq.gbl.spaces"}
      refute_received {:listed_members, _other_conversation}

      assert {:ok, %{synced_team_channels: 1, synced_group_chats: 1}} =
               TeamsChannels.sync_binding(agent_b.uid, "teams-shard-b")

      assert_received {:listed_team, "team-shard-b"}
      refute_received {:listed_team, _other_team}
      assert_received {:listed_members, "19:team-shard-b-general@thread.tacv2"}
      assert_received {:listed_members, "19:gchat-b@unq.gbl.spaces"}
      refute_received {:listed_members, _other_conversation}
    end

    test "one failing team does not park the rest of the full sync" do
      parent = self()
      %{principal: agent} = agent_fixture()
      teams_binding_fixture(agent.uid, "teams-partial")

      seed_mirror(%{
        conversation_id: "19:team-dead-general@thread.tacv2",
        team_id: "team-dead",
        app_id: @app_id
      })

      seed_mirror(%{
        conversation_id: "19:team-live-general@thread.tacv2",
        team_id: "team-live",
        app_id: @app_id
      })

      stub_team_sync(parent, %{"team-dead" => {:error, 404}})

      assert {:error, {:team_sync_failed, failures}} =
               TeamsChannels.sync_binding(agent.uid, "teams-partial")

      assert [%{team_id: "team-dead", reason: %MicrosoftOpenAPI.Error{status: 404}}] = failures

      assert_received {:listed_team, "team-live"}
      assert_received {:listed_members, "19:team-live-general@thread.tacv2"}
    end
  end

  describe "webhook dispatch" do
    test "authenticated message activities reach the gateway and bad tokens do not" do
      %{principal: agent} = agent_fixture()
      teams_binding_fixture(agent.uid, "teams-main")

      request =
        webhook_request(
          message_activity(%{
            "conversation" => %{"id" => "a:1personal", "conversationType" => "personal"},
            "text" => "hello ankole"
          })
        )

      assert {:ok, %{status: 200}} = TeamsWebhook.handle_webhook(request)

      assert {:ok, %{status: 401}} =
               TeamsWebhook.handle_webhook(%{
                 request
                 | headers: %{"authorization" => "Bearer invalid.token.value"}
               })

      unknown_app = %{request | instance_id: @tenant_id}
      assert {:ok, %{status: 401}} = TeamsWebhook.handle_webhook(unknown_app)
    end

    test "a verified app with no configured binding gets 404" do
      request =
        webhook_request(
          message_activity(%{
            "conversation" => %{"id" => "a:1personal", "conversationType" => "personal"},
            "text" => "hello"
          })
        )

      assert {:ok, %{status: 404}} = TeamsWebhook.handle_webhook(request)
    end

    test "conversation updates mirror the channel and enqueue refresh" do
      %{principal: agent} = agent_fixture()
      teams_binding_fixture(agent.uid, "teams-main")

      activity = %{
        "type" => "conversationUpdate",
        "serviceUrl" => @service_url,
        "conversation" => %{"id" => "19:room@thread.tacv2", "conversationType" => "channel"},
        "recipient" => %{"id" => "28:bot-app"},
        "membersAdded" => [%{"id" => "28:bot-app"}],
        "channelData" => %{
          "team" => %{"id" => "team-1"},
          "tenant" => %{"id" => @tenant_id}
        }
      }

      assert {:ok, %{status: 200}} = TeamsWebhook.handle_webhook(webhook_request(activity))

      signal_channel_id = Conversations.signal_channel_id("19:room@thread.tacv2")
      assert %Channel{metadata: metadata} = Repo.get(Channel, signal_channel_id)
      assert metadata["service_url"] == @service_url
      assert metadata["team_id"] == "team-1"

      assert_enqueued(
        worker: Ankole.Plugins.Microsoft365Adapter.Jobs.RefreshChannel,
        args: %{"conversation_id" => "19:room@thread.tacv2"}
      )
    end
  end

  describe "identity provider" do
    test "authorization_url uses the fixed Entra endpoint" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      assert {:ok, url} =
               IdentityProvider.authorization_url(config,
                 redirect_uri: "https://ankole.example.com/sessions/oidc/entra-id-main/callback",
                 state: "state-1"
               )

      uri = URI.parse(url)
      assert uri.host == "login.microsoftonline.com"
      assert uri.path == "/#{@tenant_id}/oauth2/v2.0/authorize"
      assert URI.decode_query(uri.query)["scope"] == "openid profile email User.Read"
    end

    test "exchange_code trades the code and reads authoritative claims from /me" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/" <> _tenant_token when conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            form = URI.decode_query(body)
            assert form["grant_type"] == "authorization_code"
            assert form["code"] == "code-1"

            Req.Test.json(conn, %{
              "access_token" => "at-1",
              "id_token" => "idt",
              "expires_in" => 3599
            })

          "/v1.0/me" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer at-1"]

            Req.Test.json(conn, %{
              "id" => "oid-ada",
              "displayName" => "Ada Lovelace",
              "mail" => "ada@example.com",
              "jobTitle" => "Engineer"
            })
        end
      end)

      assert {:ok, %{user: user}} =
               IdentityProvider.exchange_code(config, "code-1",
                 redirect_uri: "https://ankole.example.com/cb"
               )

      assert user["id"] == "oid-ada"
      assert IdentityProvider.normalize_claims(user)["displayName"] == "Ada Lovelace"
    end

    test "missing group_external_ids preserves memberships while explicit empty clears them" do
      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "entra-id-main:entra_group:g1",
                 display_name: "Engineering",
                 domain: :directory
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "entra-id-main",
                 external_kind: :directory_department,
                 external_id: "G1",
                 group_id: group.id,
                 metadata: %{"kind" => "entra_group"}
               })

      user = %{"id" => "oid-u1", "displayName" => "Ada", "mail" => "ada@example.com"}

      assert {:ok, observed} =
               IdentityProvider.upsert_user("entra-id-main", user, group_external_ids: ["G1"])

      assert Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)

      assert {:ok, _observed} = IdentityProvider.upsert_user("entra-id-main", user)
      assert Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)

      assert {:ok, _observed} =
               IdentityProvider.upsert_user("entra-id-main", user, group_external_ids: [])

      refute Repo.get_by(Membership, principal_uid: observed.principal.uid, group_id: group.id)
    end

    test "full sync projects groups then users with memberships and guest filtering" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/" <> _token_path when conn.method == "POST" ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          "/v1.0/groups" ->
            Req.Test.json(conn, %{
              "value" => [%{"id" => "g-eng", "displayName" => "Engineering"}]
            })

          "/v1.0/groups/g-eng/members" ->
            Req.Test.json(conn, %{
              "value" => [
                %{"@odata.type" => "#microsoft.graph.user", "id" => "oid-ada"},
                %{"@odata.type" => "#microsoft.graph.device", "id" => "device-1"}
              ]
            })

          "/v1.0/users" ->
            Req.Test.json(conn, %{
              "value" => [
                %{"id" => "oid-ada", "displayName" => "Ada", "userType" => "Member"},
                %{"id" => "oid-guest", "displayName" => "Guest", "userType" => "Guest"},
                %{"id" => "oid-off", "displayName" => "Off", "accountEnabled" => false}
              ]
            })
        end
      end)

      assert {:ok, %{users: 1, groups: 1}} =
               IdentityProvider.sync_directory("entra-id-main", config)

      assert {:ok, uid} =
               Ankole.Principals.resolve_platform_subject_uid("entra-id-main", "oid-ada")

      [group_id] = AuthZ.external_group_ids("entra-id-main", :directory_department, "g-eng")
      assert Repo.get_by(Membership, principal_uid: uid, group_id: group_id)

      assert {:error, :not_found} =
               Ankole.Principals.resolve_platform_subject_uid("entra-id-main", "oid-guest")
    end

    test "contact events re-fetch authoritative objects and disable deleted groups" do
      {:ok, config} = Config.validate_identity_config(identity_config())

      consumer = IdentityProvider.identity_consumer("entra-id-main", config)

      {:ok, _observed} =
        IdentityProvider.upsert_user("entra-id-main", %{"id" => "oid-m1", "displayName" => "M1"})

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/" <> _token_path when conn.method == "POST" ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          "/v1.0/users/oid-new" ->
            Req.Test.json(conn, %{"id" => "oid-new", "displayName" => "New User"})

          "/v1.0/groups/g-live" ->
            Req.Test.json(conn, %{"id" => "g-live", "displayName" => "Live Group"})

          "/v1.0/groups/g-live/members" ->
            Req.Test.json(conn, %{
              "value" => [%{"@odata.type" => "#microsoft.graph.user", "id" => "oid-m1"}]
            })
        end
      end)

      assert {:ok, [%{principal: _principal}]} =
               IdentityProvider.handle_contact_event(
                 "user.updated",
                 %{"id" => "oid-new", "resource_kind" => "user", "change_type" => "updated"},
                 [consumer]
               )

      assert {:ok, _uid} =
               Ankole.Principals.resolve_platform_subject_uid("entra-id-main", "oid-new")

      assert {:ok, [%{status: :group_updated, group_id: group_id}]} =
               IdentityProvider.handle_contact_event(
                 "group.updated",
                 %{"id" => "g-live", "resource_kind" => "group", "change_type" => "updated"},
                 [consumer]
               )

      {:ok, m1_uid} = Ankole.Principals.resolve_platform_subject_uid("entra-id-main", "oid-m1")
      assert Repo.get_by(Membership, principal_uid: m1_uid, group_id: group_id)

      assert {:ok, [%{status: :group_disabled}]} =
               IdentityProvider.handle_contact_event(
                 "group.deleted",
                 %{"id" => "g-live", "resource_kind" => "group", "change_type" => "deleted"},
                 [consumer]
               )

      refute Repo.get_by(Membership, principal_uid: m1_uid, group_id: group_id)

      assert {:ok, [%{status: :ignored_deleted_user}]} =
               IdentityProvider.handle_contact_event(
                 "user.deleted",
                 %{"id" => "oid-m1", "resource_kind" => "user", "change_type" => "deleted"},
                 [consumer]
               )
    end
  end

  describe "graph subscriptions" do
    test "ensure creates, keeps, and renews subscriptions with persisted state" do
      {:ok, config} = Config.validate_identity_config(identity_config())
      provider_id = "entra-sub-#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          conn.method == "POST" and conn.request_path == "/v1.0/subscriptions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            subscription = Torque.decode!(body)
            send(parent, {:created, subscription["resource"]})

            assert subscription["changeType"] == "updated,deleted"

            assert subscription["notificationUrl"] ==
                     "https://ankole.example.com/webhooks/v1/entra-id/#{provider_id}/directory"

            Req.Test.json(conn, %{
              "id" => "sub-#{subscription["resource"]}",
              "expirationDateTime" => subscription["expirationDateTime"]
            })

          conn.method == "PATCH" ->
            send(parent, {:renewed, conn.request_path})
            Req.Test.json(conn, %{"expirationDateTime" => "2026-07-25T00:00:00Z"})
        end
      end)

      assert {:ok, %{subscriptions: [users_entry, _groups_entry]}} =
               GraphSubscriptions.ensure(provider_id, config)

      assert_received {:created, "/users"}
      assert_received {:created, "/groups"}
      assert GraphSubscriptions.valid_client_state?(provider_id, users_entry["clientState"])
      refute GraphSubscriptions.valid_client_state?(provider_id, "wrong-secret")

      assert {:ok, %{"subscriptions" => [_users, _groups]} = state} =
               AppConfigure.get_by_key(Config.subscription_state_key(provider_id))

      refute Map.has_key?(state, "updatedAt")

      # A second run inside the renewal window keeps entries untouched.
      assert {:ok, _result} =
               GraphSubscriptions.ensure(provider_id, config)

      refute_received {:created, _resource}
      refute_received {:renewed, _path}

      # Advancing past the renewal window renews in place.
      future = DateTime.add(DateTime.utc_now(), 6, :day)

      assert {:ok, _result} =
               GraphSubscriptions.ensure(provider_id, config, now: future)

      assert_received {:renewed, "/v1.0/subscriptions/sub-/users"}
    end

    test "delete keeps failed subscriptions in local state for retry" do
      {:ok, config} = Config.validate_identity_config(identity_config())
      provider_id = "entra-delete-#{System.unique_integer([:positive])}"
      parent = self()

      subscriptions = [
        %{
          "id" => "sub-users",
          "resource" => "/users",
          "expiration" => "2026-07-25T00:00:00Z",
          "clientState" => "users-secret"
        },
        %{
          "id" => "sub-groups",
          "resource" => "/groups",
          "expiration" => "2026-07-25T00:00:00Z",
          "clientState" => "groups-secret"
        }
      ]

      assert {:ok, _state} =
               AppConfigure.put_global_by_key(Config.subscription_state_key(provider_id), %{
                 "subscriptions" => subscriptions
               })

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          conn.method == "DELETE" and
              conn.request_path == "/v1.0/subscriptions/sub-users" ->
            send(parent, {:deleted, "sub-users"})
            Plug.Conn.send_resp(conn, 204, "")

          conn.method == "DELETE" and
              conn.request_path == "/v1.0/subscriptions/sub-groups" ->
            send(parent, {:delete_failed, "sub-groups"})

            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"error" => %{"code" => "ServiceUnavailable"}})
        end
      end)

      assert {:error,
              {:graph_subscription_deletion_failed,
               [%{subscription_id: "sub-groups", reason: %MicrosoftOpenAPI.Error{status: 503}}]}} =
               GraphSubscriptions.delete_all(provider_id, config)

      assert_received {:deleted, "sub-users"}
      assert_received {:delete_failed, "sub-groups"}

      assert {:ok, %{"subscriptions" => [remaining]}} =
               AppConfigure.get_by_key(Config.subscription_state_key(provider_id))

      assert remaining["id"] == "sub-groups"
    end

    test "a resource failure keeps the succeeded resource persisted and retries only the failure" do
      {:ok, config} = Config.validate_identity_config(identity_config())
      provider_id = "entra-partial-#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          conn.method == "POST" and conn.request_path == "/v1.0/subscriptions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            subscription = Torque.decode!(body)

            case subscription["resource"] do
              "/users" ->
                send(parent, {:created, "/users"})

                Req.Test.json(conn, %{
                  "id" => "sub-users",
                  "expirationDateTime" => subscription["expirationDateTime"]
                })

              "/groups" ->
                send(parent, {:denied, "/groups"})

                conn
                |> Plug.Conn.put_status(403)
                |> Req.Test.json(%{"error" => %{"code" => "Authorization_RequestDenied"}})
            end
        end
      end)

      assert {:error, {:graph_subscription_ensure_failed, [failure]}} =
               GraphSubscriptions.ensure(provider_id, config)

      assert %{resource: "/groups", reason: %MicrosoftOpenAPI.Error{status: 403}} = failure
      assert_received {:created, "/users"}
      assert_received {:denied, "/groups"}

      assert {:ok, %{"subscriptions" => [users_entry]}} =
               AppConfigure.get_by_key(Config.subscription_state_key(provider_id))

      assert users_entry["resource"] == "/users"
      assert users_entry["id"] == "sub-users"

      # After the permission is granted, the second run only creates /groups.
      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          conn.method == "POST" and conn.request_path == "/v1.0/subscriptions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            subscription = Torque.decode!(body)
            send(parent, {:created, subscription["resource"]})

            Req.Test.json(conn, %{
              "id" => "sub-#{subscription["resource"]}",
              "expirationDateTime" => subscription["expirationDateTime"]
            })
        end
      end)

      assert {:ok, %{subscriptions: [kept_users, groups_entry]}} =
               GraphSubscriptions.ensure(provider_id, config)

      assert kept_users["id"] == "sub-users"
      assert groups_entry["resource"] == "/groups"
      assert_received {:created, "/groups"}
      refute_received {:created, "/users"}

      assert {:ok, %{"subscriptions" => persisted}} =
               AppConfigure.get_by_key(Config.subscription_state_key(provider_id))

      assert Enum.map(persisted, & &1["resource"]) |> Enum.sort() == ["/groups", "/users"]
    end
  end

  describe "directory webhook" do
    test "echoes the validation token as text/plain" do
      request = %{
        handler_id: "entra-id",
        instance_id: "entra-id-main",
        kind: "directory",
        query_params: %{"validationToken" => "token-123"},
        body_params: %{},
        headers: %{}
      }

      assert {:ok, %{status: 200, body: "token-123", content_type: "text/plain"}} =
               DirectoryWebhook.handle_webhook(request)
    end

    test "normalizes notifications and enforces clientState" do
      assert {:ok, "user.updated", %{"id" => "oid-1"}} =
               DirectoryWebhook.normalize_notification(%{
                 "changeType" => "updated",
                 "resource" => "Users/oid-1",
                 "resourceData" => %{"id" => "oid-1", "@odata.type" => "#Microsoft.Graph.User"}
               })

      assert {:ok, "group.deleted", %{"id" => "g-1"}} =
               DirectoryWebhook.normalize_notification(%{
                 "changeType" => "deleted",
                 "resource" => "Groups/g-1",
                 "resourceData" => %{"id" => "g-1", "@odata.type" => "#Microsoft.Graph.Group"}
               })

      assert :skip = DirectoryWebhook.normalize_notification(%{"changeType" => "updated"})
    end

    test "processes authentic notifications for an active provider" do
      provider_id = "entra-id-main"

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          conn.method == "POST" and conn.request_path == "/v1.0/subscriptions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            subscription = Torque.decode!(body)

            Req.Test.json(conn, %{
              "id" => "sub-x",
              "expirationDateTime" => subscription["expirationDateTime"]
            })

          conn.request_path == "/v1.0/users/oid-webhook" ->
            Req.Test.json(conn, %{"id" => "oid-webhook", "displayName" => "Webhook User"})
        end
      end)

      assert {:ok, _provider} =
               IdentityProviders.save_provider(provider_id, "entra-id", identity_config(), true,
                 reconcile_realtime?: false
               )

      {:ok, config} = Config.load_identity_config_key(Config.identity_config_key(provider_id))

      assert {:ok, %{subscriptions: [users_entry | _rest]}} =
               GraphSubscriptions.ensure(provider_id, config)

      request = %{
        handler_id: "entra-id",
        instance_id: provider_id,
        kind: "directory",
        query_params: %{},
        body_params: %{
          "value" => [
            %{
              "clientState" => users_entry["clientState"],
              "changeType" => "updated",
              "resource" => "Users/oid-webhook",
              "resourceData" => %{
                "id" => "oid-webhook",
                "@odata.type" => "#Microsoft.Graph.User"
              }
            },
            %{
              "clientState" => "forged",
              "changeType" => "updated",
              "resource" => "Users/oid-forged",
              "resourceData" => %{"id" => "oid-forged", "@odata.type" => "#Microsoft.Graph.User"}
            }
          ]
        },
        headers: %{}
      }

      assert {:ok, %{status: 202}} = DirectoryWebhook.handle_webhook(request)

      assert {:ok, _uid} =
               Ankole.Principals.resolve_platform_subject_uid(provider_id, "oid-webhook")

      assert {:error, :not_found} =
               Ankole.Principals.resolve_platform_subject_uid(provider_id, "oid-forged")
    end
  end

  describe "subscription reconciler" do
    test "ensures subscriptions for realtime providers and removes them when disabled" do
      provider_id = "entra-recon-#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
            Req.Test.json(conn, %{"access_token" => "cc", "expires_in" => 3600})

          conn.method == "POST" and conn.request_path == "/v1.0/subscriptions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            subscription = Torque.decode!(body)
            send(parent, {:created, subscription["resource"]})

            Req.Test.json(conn, %{
              "id" => "sub-r",
              "expirationDateTime" => subscription["expirationDateTime"]
            })

          conn.method == "DELETE" ->
            send(parent, {:deleted, conn.request_path})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:ok, _provider} =
               IdentityProviders.save_provider(provider_id, "entra-id", identity_config(), true,
                 reconcile_realtime?: false
               )

      assert %{ensured: ensured, errors: []} =
               SubscriptionReconciler.reconcile_once()

      assert ensured >= 1
      assert_received {:created, "/users"}

      disabled = Map.put(identity_config(), "sync", %{"realtime" => false})

      assert {:ok, _provider} =
               IdentityProviders.save_provider(provider_id, "entra-id", disabled, true,
                 reconcile_realtime?: false
               )

      assert %{removed: removed, errors: []} =
               SubscriptionReconciler.reconcile_once()

      assert removed >= 1
      assert_received {:deleted, "/v1.0/subscriptions/sub-r"}
    end
  end

  defp identity_config do
    %{
      "tenantID" => @tenant_id,
      "clientID" => "client-1",
      "clientSecret" => "secret-1",
      "publicBaseURL" => "https://ankole.example.com"
    }
  end

  defp webhook_request(activity) do
    stub_bot_openid!()

    %{
      handler_id: "teams",
      instance_id: @app_id,
      kind: "messages",
      query_params: %{},
      body_params: activity,
      headers: %{"authorization" => "Bearer " <> @rs256_token}
    }
  end

  defp stub_bot_openid! do
    Req.Test.stub(BotOpenIDStub, fn conn ->
      case conn.request_path do
        "/v1/.well-known/keys" ->
          Req.Test.json(conn, %{
            "keys" => [%{"kty" => "RSA", "kid" => "test-key-1", "n" => @jwk_n, "e" => "AQAB"}]
          })

        _metadata ->
          Req.Test.json(conn, %{
            "issuer" => "https://api.botframework.com",
            "jwks_uri" => "https://login.bot.test/v1/.well-known/keys"
          })
      end
    end)

    Req.default_options(plug: {Req.Test, BotOpenIDStub})
  end

  defp chat_consumer(overrides \\ %{}) do
    context =
      AdapterContext.new(
        agent_uid: "agent-1",
        binding_name: "teams",
        adapter: "teams",
        user_name: "Teams"
      )

    Inbound.chat_consumer(context, Map.merge(validated_chat_config(), overrides))
  end

  defp default_microsoft_request(%{request_path: "/report.xlsx"} = conn) do
    conn
    |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="report.xlsx"))
    |> Plug.Conn.send_resp(200, "xlsx")
  end

  defp default_microsoft_request(conn) do
    conn
    |> Plug.Conn.put_status(404)
    |> Req.Test.json(%{"error" => %{"code" => "not_stubbed"}})
  end

  defp validated_chat_config(overrides \\ %{}) do
    {:ok, config} = Config.validate_chat_config(chat_config())
    Map.merge(config, overrides)
  end

  defp chat_config do
    %{
      "appID" => @app_id,
      "appPassword" => "app-password",
      "tenantID" => @tenant_id
    }
  end

  defp seed_mirror(attrs) do
    assert {:ok, _channel} =
             TeamsChannels.upsert_channel_projection(
               Map.merge(
                 %{conversation_type: "channel", service_url: @service_url, name: "Seeded"},
                 attrs
               ),
               nil
             )
  end

  defp stub_team_sync(parent, responses) do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/oauth2/v2.0/token") ->
          Req.Test.json(conn, %{"access_token" => "bot-token", "expires_in" => 3600})

        String.contains?(conn.request_path, "/v3/teams/") and
            String.ends_with?(conn.request_path, "/conversations") ->
          team_id = conn.request_path |> String.split("/") |> Enum.at(-2) |> URI.decode()
          send(parent, {:listed_team, team_id})

          case Map.get(responses, team_id, :ok) do
            :ok ->
              Req.Test.json(conn, %{
                "conversations" => [
                  %{"id" => "19:#{team_id}-general@thread.tacv2", "name" => "General"}
                ]
              })

            {:error, status} ->
              conn
              |> Plug.Conn.put_status(status)
              |> Req.Test.json(%{"error" => %{"code" => "NotFound"}})
          end

        String.ends_with?(conn.request_path, "/pagedmembers") ->
          conversation_id =
            conn.request_path |> String.split("/") |> Enum.at(-2) |> URI.decode()

          send(parent, {:listed_members, conversation_id})

          Req.Test.json(conn, %{
            "members" => [%{"id" => "29:user", "aadObjectId" => "oid-shard", "name" => "Ada"}]
          })
      end
    end)
  end

  defp teams_binding_fixture(agent_uid, name, config \\ chat_config()) do
    {:ok, _config} =
      AppConfigure.put_global_by_key(Config.chat_config_key(name), config)

    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "teams",
        config_ref: "app-config://" <> Config.chat_config_key(name),
        unaddressed_group_message_policy: :ignore,
        unmatched_sender_policy: :create_standalone
      })

    binding
  end

  defp message_activity(overrides) do
    Map.merge(
      %{
        "type" => "message",
        "id" => "activity-#{System.unique_integer([:positive])}",
        "timestamp" => "2026-07-13T10:00:00.000Z",
        "serviceUrl" => @service_url,
        "channelId" => "msteams",
        "from" => %{"id" => "29:user", "aadObjectId" => "oid-user", "name" => "User One"},
        "recipient" => %{"id" => "28:bot-app", "name" => "Ankole"},
        "conversation" => %{
          "id" => "19:room@thread.tacv2;messageid=1690000000001",
          "conversationType" => "channel"
        },
        "channelData" => %{
          "team" => %{"id" => "team-1"},
          "tenant" => %{"id" => @tenant_id}
        }
      },
      overrides
    )
  end

  defp agent_fixture do
    Ankole.PrincipalsFixtures.agent_fixture(%{
      uid: "agent-#{System.unique_integer([:positive])}",
      display_name: "Agent",
      role: "Operator"
    })
  end
end
