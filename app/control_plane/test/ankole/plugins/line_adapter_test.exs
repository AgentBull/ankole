defmodule Ankole.Plugins.LineAdapterTest do
  use Ankole.DataCase, async: false
  import Ankole.ExternalConversationsFixtures

  import Ankole.FilesFixtures, only: [assert_stored_attachment!: 5]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures
  import Ankole.Eventually, only: [eventually: 1]

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Plugins.LineAdapter

  alias Ankole.Plugins.LineAdapter.Config
  alias Ankole.Plugins.LineAdapter.Inbound
  alias Ankole.Plugins.LineAdapter.Delivery
  alias Ankole.Plugins.LineAdapter.Presentation
  alias Ankole.Plugins.LineAdapter.Profile
  alias Ankole.Plugins.LineAdapter.Signature
  alias Ankole.Plugins.LineAdapter.Webhook

  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests

  alias Ankole.Conversations.Delivery.ActionToken

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.Message

  import Ankole.Conversations.Assertions,
    only: [message_snapshot: 1, message_snapshot!: 1, observation_snapshot: 1]

  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.InteractionState
  alias Ankole.Conversations.Delivery.ReplyPresentation

  @channel_id "1650000001"
  @channel_secret "line-channel-secret"
  @access_token "line-long-lived-token"
  @bot_user_id "Ubot00000000000000000000000000000"
  @user_id "U4af4980629000000000000000000001"
  @dm_channel "line:#{@bot_user_id}:user:#{@user_id}"
  @group_id "Ca56f9463700000000000000000000001"

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [
        api_base_url: "https://line.test",
        data_base_url: "https://line-data.test",
        plug: {Req.Test, __MODULE__}
      ]
    )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v2/bot/profile/" <> _user_id ->
          Req.Test.json(conn, %{"displayName" => "Ada", "userId" => @user_id})

        "/v2/bot/group/" <> _rest ->
          Req.Test.json(conn, %{"displayName" => "Ada in group", "userId" => @user_id})

        "/v2/bot/message/push" ->
          Req.Test.json(conn, %{"sentMessages" => [%{"id" => "sent-1", "quoteToken" => "qt-1"}]})

        _other ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not found"})
      end
    end)

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
    test "declares one consumer IM adapter and its webhook handler" do
      assert LineAdapter.plugin_id() == "line-adapter"
      assert [adapter, handler] = LineAdapter.adapter_declarations()
      assert adapter.id == "line"
      assert adapter.adapter_category == "consumer_im"
      assert adapter.author_hydrator == Profile
      refute Map.has_key?(adapter, :preview_module)

      assert adapter.supported_group_message_modes == [
               "addressed_only",
               "observe_all",
               "may_intervene"
             ]

      assert adapter.inbound_capabilities == ["entry_receive", "entry_removed", "action_event"]

      assert adapter.outbound_capabilities == [
               "post_entry",
               "reply_entry",
               "divider",
               "card",
               "outbound_reconciliation"
             ]

      assert Enum.map(adapter.fields, & &1.path) == [
               "channelId",
               "channelSecret",
               "channelAccessToken"
             ]

      assert Enum.map(adapter.fields, & &1.encrypted) == [false, true, true]

      assert handler.contract_id == "signals.webhook_handler"
      assert handler.id == "line"
      assert handler.module == Webhook
      assert handler.kinds == ["events"]
    end

    test "keeps two Agents' same-name bindings on distinct config keys" do
      assert Config.binding_config_key("agent-a", "line-main") !=
               Config.binding_config_key("agent-b", "line-main")
    end

    test "validates the channel id and both secrets and redacts them from inspection" do
      assert {:ok, config} = Config.validate_binding_config(binding_config())
      assert config["channelId"] == @channel_id

      assert {:error, :invalid_line_channel_id} =
               Config.validate_binding_config(Map.put(binding_config(), "channelId", "abc"))

      assert {:error, _reason} =
               Config.validate_binding_config(Map.delete(binding_config(), "channelSecret"))

      runtime = %Config.Runtime{
        channel_id: @channel_id,
        channel_secret: @channel_secret,
        channel_access_token: @access_token
      }

      rendered = inspect(runtime)
      assert rendered =~ @channel_id
      refute rendered =~ @channel_secret
      refute rendered =~ @access_token
      refute inspect(Config.client(config)) =~ @access_token
    end

    test "one channel can belong to only one enabled binding" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()
      attrs = %{"config" => binding_config()}

      assert {:ok, _binding} =
               Ankole.Signals.Bindings.put_binding(first_agent.uid, "line", "line-one", attrs)

      {:ok, application} = Config.platform_application(binding_config())

      assert {:error, {:platform_application_already_bound, ^application, first_uid, "line-one"}} =
               Ankole.Signals.Bindings.put_binding(second_agent.uid, "line", "line-two", attrs)

      assert first_uid == first_agent.uid

      assert {:ok, _disabled} =
               Ankole.Signals.Bindings.disable_binding(
                 Ankole.Signals.get_agent_binding!(first_agent.uid, "line-one").id
               )

      assert {:ok, _binding} =
               Ankole.Signals.Bindings.put_binding(second_agent.uid, "line", "line-two", attrs)
    end
  end

  describe "signature" do
    test "accepts the Base64 HMAC-SHA256 of the exact bytes and nothing else" do
      body = ~s({"destination":"#{@bot_user_id}","events":[]})
      signature = Base.encode64(:crypto.mac(:hmac, :sha256, @channel_secret, body))

      assert Signature.valid?(body, signature, @channel_secret)
      refute Signature.valid?(body <> " ", signature, @channel_secret)
      refute Signature.valid?(body, signature, "other-secret")
      refute Signature.valid?(body, nil, @channel_secret)
    end
  end

  describe "inbound projection" do
    test "projects direct and group messages with stable identities and mention removal" do
      consumer = consumer("agent-a", "line-main", nil, Ecto.UUID.generate())

      assert {:ok, dm} =
               Inbound.normalize_message_receive(
                 envelope(message_event(user_source(), text_message("hello"))),
                 consumer
               )

      assert dm.explicit
      assert dm.provider_conversation_id == "line:#{@bot_user_id}:user:#{@user_id}"
      assert is_nil(dm.provider_thread_id)
      assert dm.channel.kind == :im_dm
      assert dm.author["provider"] == "line"
      assert dm.author["platform_subject"] == @user_id
      assert dm.metadata["quote_token"] == "quote-token-1"
      refute Map.has_key?(dm.author, "email")

      mentioned =
        text_message("😀 @Ankole please check")
        |> Map.put("mention", %{
          "mentionees" => [
            %{
              "index" => 3,
              "length" => 7,
              "type" => "user",
              "userId" => @bot_user_id,
              "isSelf" => true
            }
          ]
        })

      assert {:ok, group} =
               Inbound.normalize_message_receive(
                 envelope(message_event(group_source(), mentioned)),
                 consumer
               )

      assert group.explicit
      assert group.text == "😀  please check" |> String.trim()
      assert group.channel.kind == :im_group
      assert group.provider_conversation_id == "line:#{@bot_user_id}:group:#{@group_id}"
      assert [%{"kind" => "bot", "targets_current_agent" => true}] = group.mentions
      assert group.author["metadata"]["group_id"] == @group_id

      assert {:ok, plain} =
               Inbound.normalize_message_receive(
                 envelope(message_event(group_source(), text_message("just chatting"))),
                 consumer
               )

      refute plain.explicit
    end

    test "a quote of a message the Agent sent makes a group message explicit" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-quote")

      Ankole.SignalsFixtures.delivery_fixture!(%{
        agent_uid: agent.uid,
        binding_name: "line-quote",
        outbound_key: "ai-reply:1",
        operation: :post,
        status: :sent,
        conversation_id: external_conversation_id("line:#{@bot_user_id}:group:#{@group_id}"),
        created_provider_message_id: "bot-message-1",
        payload: %{}
      })

      consumer = consumer(agent.uid, "line-quote")

      quoted =
        text_message("what about this?") |> Map.put("quotedMessageId", "bot-message-1")

      assert {:ok, projected} =
               Inbound.normalize_message_receive(
                 envelope(message_event(group_source(), quoted)),
                 consumer
               )

      assert projected.explicit
      assert projected.reply_to_provider_message_id == "bot-message-1"

      other = text_message("what about this?") |> Map.put("quotedMessageId", "human-message-9")

      assert {:ok, unrelated} =
               Inbound.normalize_message_receive(
                 envelope(message_event(group_source(), other)),
                 consumer
               )

      refute unrelated.explicit
    end

    test "a quote of another human stays unaddressed after the Agent has posted in the group" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               put_line_binding(agent.uid, "line-group", %{
                 "group_message_mode" => "addressed_only"
               })

      consumer = consumer(agent.uid, "line-group")
      human_message = text_message("human conversation")

      assert {:ok, [_recorded_or_ignored]} =
               Inbound.handle_message_receive(
                 "message",
                 envelope(message_event(group_source(), human_message)),
                 [consumer]
               )

      channel_id = "line:#{@bot_user_id}:group:#{@group_id}"

      {:ok, row} =
        Ankole.SignalsFixtures.commit_delivery(%{
          agent_uid: agent.uid,
          binding_name: "line-group",
          outbound_key: "earlier-bot-post",
          operation: :post,
          conversation_id: external_conversation_id(channel_id),
          payload: %{},
          fallback_visible_text: "earlier bot message"
        })

      assert {:ok, %{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch_by_key(
                 row.agent_uid,
                 row.binding_name,
                 row.outbound_key
               )

      quoting_human =
        text_message("/stop") |> Map.put("quotedMessageId", human_message["id"])

      incoming = envelope(message_event(group_source(), quoting_human))

      assert {:ok, %{explicit: false, provider_thread_id: nil}} =
               Inbound.normalize_message_receive(incoming, consumer)

      assert {:ok, [%{status: status}]} =
               Inbound.handle_message_receive("message", incoming, [consumer])

      assert status in [:ignored, :recorded]
      refute "command.stop" in Enum.map(Repo.all(Signal), & &1.type)
    end

    test "a quote of any message of a split reply makes the group message explicit" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               put_line_binding(agent.uid, "line-split", %{
                 "group_message_mode" => "addressed_only"
               })

      consumer = consumer(agent.uid, "line-split")

      assert {:ok, [_recorded_or_ignored]} =
               Inbound.handle_message_receive(
                 "message",
                 envelope(message_event(group_source(), text_message("hello"))),
                 [consumer]
               )

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"sentMessages" => [%{"id" => "part-one"}, %{"id" => "part-two"}]})
      end)

      {:ok, row} =
        Ankole.SignalsFixtures.commit_delivery(%{
          agent_uid: agent.uid,
          binding_name: "line-split",
          outbound_key: "split-1",
          operation: :post,
          conversation_id: external_conversation_id("line:#{@bot_user_id}:group:#{@group_id}"),
          payload: %{},
          fallback_visible_text: String.duplicate("A", 5001)
        })

      assert {:ok, %{status: :sent, created_provider_message_id: "part-one"}} =
               Ankole.Conversations.Delivery.dispatch_by_key(
                 row.agent_uid,
                 row.binding_name,
                 row.outbound_key
               )

      assert %Intent{payload: %{"line_message_ids" => ["part-one", "part-two"]}} =
               Repo.get_by!(Intent, outbound_key: "split-1")

      second =
        envelope(
          message_event(
            group_source(),
            text_message("explain this") |> Map.put("quotedMessageId", "part-two")
          )
        )

      assert {:ok, %{explicit: true}} = Inbound.normalize_message_receive(second, consumer)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", second, [consumer])
    end

    test "ignores standby events, unattributed group messages, and unsupported types" do
      consumer = consumer("agent-a", "line-main", nil, Ecto.UUID.generate())

      standby = message_event(user_source(), text_message("hello")) |> Map.put("mode", "standby")

      assert {:ignore, :standby_mode} =
               Inbound.normalize_message_receive(envelope(standby), consumer)

      anonymous = message_event(%{"type" => "group", "groupId" => @group_id}, text_message("hi"))

      assert {:ignore, :missing_user_id} =
               Inbound.normalize_message_receive(envelope(anonymous), consumer)

      template = message_event(user_source(), %{"id" => "m-1", "type" => "template"})

      assert {:ignore, :unsupported_message_type} =
               Inbound.normalize_message_receive(envelope(template), consumer)

      sticker =
        message_event(user_source(), %{
          "id" => "m-2",
          "type" => "sticker",
          "packageId" => "446",
          "stickerId" => "1988"
        })

      assert {:ok, %{text: "Sticker: 446/1988", attachments: []}} =
               Inbound.normalize_message_receive(envelope(sticker), consumer)
    end

    test "keeps an over-limit or external media fact but never invents a readable path" do
      consumer = consumer("agent-a", "line-main", nil, Ecto.UUID.generate())

      large =
        message_event(user_source(), %{
          "id" => "m-large",
          "type" => "file",
          "fileName" => "archive.zip",
          "fileSize" => 26 * 1024 * 1024,
          "contentProvider" => %{"type" => "line"}
        })

      assert {:ok, %{attachments: [attachment]}} =
               Inbound.normalize_message_receive(envelope(large), consumer)

      assert attachment["materialization_state"] == "provider_download_limit"
      assert attachment["restriction"] =~ "25 MB"
      refute Map.has_key?(attachment, "object_id")

      external =
        message_event(user_source(), %{
          "id" => "m-external",
          "type" => "image",
          "contentProvider" => %{
            "type" => "external",
            "originalContentUrl" => "https://example.test/photo.jpg",
            "previewImageUrl" => "https://example.test/preview.jpg"
          }
        })

      assert {:ok, %{attachments: [external_attachment]}} =
               Inbound.normalize_message_receive(envelope(external), consumer)

      assert external_attachment["materialization_state"] == "provider_external_content"
      assert external_attachment["url"] == "https://example.test/photo.jpg"
      refute Map.has_key?(external_attachment, "provider_file_id")
    end

    test "assigns the durable attachment ID before storing an admitted file" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-media")

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:line_request, conn.request_path})

        case conn.request_path do
          "/v2/bot/profile/" <> _user_id ->
            Req.Test.json(conn, %{"displayName" => "Ada", "userId" => @user_id})

          "/v2/bot/message/m-photo/content" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/jpeg")
            |> Plug.Conn.send_resp(200, "attachment")
        end
      end)

      photo =
        message_event(user_source(), %{
          "id" => "m-photo",
          "type" => "image",
          "contentProvider" => %{"type" => "line"}
        })

      assert {:ok, [result]} =
               Inbound.handle_message_receive("message", envelope(photo), [
                 consumer(agent.uid, "line-media")
               ])

      # The webhook answer carries the pending observation; the download runs
      # after it, so the durable ID exists before any bytes move.
      assert %{attachments: [pending]} = observation_snapshot(result.message_observation)
      assert is_integer(pending["attachment_id"])
      refute pending["materialization_state"] == "complete"

      assert eventually(fn ->
               entry =
                 message_snapshot(
                   conversation_id:
                     observation_snapshot(result.message_observation).conversation_id,
                   provider_message_id: "m-photo"
                 )

               match?(%{attachments: [%{"materialization_state" => "complete"}]}, entry)
             end)

      %{attachments: [attachment]} =
        message_snapshot(
          conversation_id: observation_snapshot(result.message_observation).conversation_id,
          provider_message_id: "m-photo"
        )

      assert attachment["attachment_id"] == pending["attachment_id"]
      assert attachment["mimetype"] == "image/jpeg"

      assert_stored_attachment!(
        agent.uid,
        external_conversation_id(@dm_channel),
        attachment,
        "attachment",
        "image-m-photo.jpg"
      )

      assert_received {:line_request, "/v2/bot/message/m-photo/content"}

      # LINE redelivers the same event after a non-2xx answer. The completed
      # download stays, and no second fetch runs, even when LINE would now
      # answer the content request with an error.
      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:line_request, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      assert {:ok, [redelivered]} =
               Inbound.handle_message_receive("message", envelope(photo), [
                 consumer(agent.uid, "line-media")
               ])

      assert %{attachments: [kept]} = observation_snapshot(redelivered.message_observation)
      assert kept["materialization_state"] == "complete"
      assert kept["object_id"] == attachment["object_id"]
      assert kept["attachment_id"] == attachment["attachment_id"]
      refute_received {:line_request, "/v2/bot/message/m-photo/content"}

      %{attachments: [stored], metadata: metadata} =
        message_snapshot(
          conversation_id: observation_snapshot(result.message_observation).conversation_id,
          provider_message_id: "m-photo"
        )

      assert stored["path"] == attachment["path"]
      assert metadata["attachment_materialization"]["state"] == "complete"

      assert metadata["attachment_materialization"]["observed_at"] ==
               observation_snapshot(result.message_observation).metadata[
                 "attachment_materialization"
               ]["observed_at"]

      refute Map.get(redelivered, :signal)

      refute Enum.any?(
               Repo.all(Signal),
               &(&1.agent_uid == agent.uid and &1.event_type == "input.revised")
             )
    end

    test "a redelivery during the download fetches again and a late failure cannot lose the file" do
      %{fixture: fixture, release: release, agent: agent} =
        blocking_download_fixture("line-overlap", "m-slow")

      photo = fixture.photo
      consumer = fixture.consumer

      assert {:ok, [first]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert %{attachments: [pending]} = observation_snapshot(first.message_observation)
      assert_receive {:download_waiting, first_download}, 2_000

      assert {:ok, [second]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert %{attachments: [reused]} = observation_snapshot(second.message_observation)
      assert reused["attachment_id"] == pending["attachment_id"]
      assert_receive {:download_waiting, second_download}, 2_000

      release.(first_download, :finish_success)
      channel_id = observation_snapshot(first.message_observation).conversation_id
      assert eventually(fn -> complete?(channel_id, "m-slow") end)

      # The second fetch fails after the first one wrote the bytes; the entry
      # keeps the readable result under the gateway's merge rule.
      release.(second_download, :finish_failure)
      assert eventually(fn -> not Process.alive?(second_download) end)
      assert complete?(channel_id, "m-slow")

      %{attachments: [attachment]} =
        message_snapshot(
          conversation_id: external_conversation_id(channel_id),
          provider_message_id: "m-slow"
        )

      assert attachment["attachment_id"] == pending["attachment_id"]

      assert_stored_attachment!(
        agent.uid,
        external_conversation_id(@dm_channel),
        attachment,
        "attachment",
        "image-m-slow.jpg"
      )
    end

    test "a redelivery after the download task died fetches again" do
      %{fixture: fixture, release: release} = blocking_download_fixture("line-dead", "m-dead")
      photo = fixture.photo
      consumer = fixture.consumer

      assert {:ok, [first]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert %{attachments: [pending]} = observation_snapshot(first.message_observation)
      assert_receive {:download_waiting, dead_download}, 2_000

      Process.exit(dead_download, :kill)
      assert eventually(fn -> not Process.alive?(dead_download) end)

      assert {:ok, [_second]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert_receive {:download_waiting, replacement}, 2_000
      release.(replacement, :finish_success)

      channel_id = observation_snapshot(first.message_observation).conversation_id
      assert eventually(fn -> complete?(channel_id, "m-dead") end)

      %{attachments: [attachment]} =
        message_snapshot(
          conversation_id: external_conversation_id(channel_id),
          provider_message_id: "m-dead"
        )

      assert attachment["attachment_id"] == pending["attachment_id"]
    end

    test "a moved route puts the stored file in the new Agent's drive without a download" do
      %{fixture: fixture, release: release, agent: first_agent} =
        blocking_download_fixture("line-moved", "m-moved")

      photo = fixture.photo

      assert {:ok, [first]} =
               Inbound.handle_message_receive("message", envelope(photo), [fixture.consumer])

      assert %{attachments: [pending]} = observation_snapshot(first.message_observation)
      assert_receive {:download_waiting, download}, 2_000
      release.(download, :finish_success)
      channel_id = observation_snapshot(first.message_observation).conversation_id
      assert eventually(fn -> complete?(channel_id, "m-moved") end)

      %{attachments: [first_copy]} =
        message_snapshot(
          conversation_id: external_conversation_id(channel_id),
          provider_message_id: "m-moved"
        )

      assert_stored_attachment!(
        first_agent.uid,
        external_conversation_id(@dm_channel),
        first_copy,
        "attachment",
        "image-m-moved.jpg"
      )

      # The operator moves the route: the old binding is disabled and the
      # channel now belongs to another Agent. The stored bytes serve every
      # Agent, so nothing is downloaded again, and the drive of the new Agent
      # gets its own entry for them.
      assert {:ok, _disabled} =
               Ankole.Signals.Bindings.disable_binding(
                 Ankole.Signals.get_agent_binding!(first_agent.uid, "line-moved").id
               )

      %{principal: second_agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(second_agent.uid, "line-moved")

      assert {:ok, [moved]} =
               Inbound.handle_message_receive("message", envelope(photo), [
                 consumer(second_agent.uid, "line-moved")
               ])

      refute_receive {:download_waiting, _download}, 200
      assert %{attachments: [kept]} = observation_snapshot(moved.message_observation)
      assert kept["attachment_id"] == pending["attachment_id"]
      assert kept["materialization_state"] == "complete"
      assert kept["object_id"] == first_copy["object_id"]

      assert_stored_attachment!(
        second_agent.uid,
        external_conversation_id(@dm_channel),
        kept,
        "attachment",
        "image-m-moved.jpg"
      )
    end
  end

  describe "webhook dispatch" do
    test "verifies the signature, stores each event once, and answers the Verify probe" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-main")

      request = signed_request([message_event(user_source(), text_message("hello"))])

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(request)
      assert Repo.aggregate(Message, :count) == 1

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(request)
      assert Repo.aggregate(Message, :count) == 1

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request([]))

      forged = %{
        request
        | headers: %{
            "x-line-signature" =>
              Base.encode64(:crypto.mac(:hmac, :sha256, @channel_secret, "{}"))
          }
      }

      assert {:ok, %{status: 401}} = Webhook.handle_webhook(forged)

      assert {:ok, %{status: 404}} = Webhook.handle_webhook(%{request | instance_id: "999"})
      assert Repo.aggregate(Message, :count) == 1
    end

    test "an unsend event removes the mirrored message" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-main")

      event = message_event(user_source(), text_message("delete me"))
      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request([event]))
      assert %{} = message_snapshot(provider_message_id: event["message"]["id"])

      unsend = %{
        "type" => "unsend",
        "mode" => "active",
        "timestamp" => 1_787_000_001_000,
        "webhookEventId" => "01LINEUNSEND0000000000000001",
        "deliveryContext" => %{"isRedelivery" => false},
        "source" => user_source(),
        "unsend" => %{"messageId" => event["message"]["id"]}
      }

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request([unsend]))
      assert is_nil(message_snapshot(provider_message_id: event["message"]["id"]))
    end
  end

  describe "identity admission" do
    test "manual review holds an unknown sender with a hydrated name until an admin maps it" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               put_line_binding(agent.uid, "line-review", %{
                 "unmatched_sender_policy" => "manual_review"
               })

      consumer = consumer(agent.uid, "line-review")
      first = message_event(user_source(), text_message("hello"))

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               Inbound.handle_message_receive("message", envelope(first), [consumer])

      assert [request] = MappingRequests.list_requests()
      assert request.provider == "line"
      assert request.external_id == @user_id
      assert request.display_name == "Ada"
      assert Repo.aggregate(Message, :count) == 0

      assert %Intent{operation: :reply, fallback_visible_text: notice} =
               Repo.one!(Intent)

      assert notice == Ankole.I18n.t("conversations.delivery.reply.unmapped_sender")

      %{principal: human} = human_fixture()
      assert {:ok, _mapping} = MappingRequests.bind_request(request.id, human.uid)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 envelope(message_event(user_source(), text_message("resend"))),
                 [consumer]
               )

      assert {:ok, matched} = Principals.resolve_platform_subject("line", @user_id)
      assert matched.uid == human.uid
    end

    test "create_standalone names the new account from the LINE profile" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-standalone")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 envelope(message_event(user_source(), text_message("hello"))),
                 [consumer(agent.uid, "line-standalone")]
               )

      assert {:ok, principal} = Principals.resolve_platform_subject("line", @user_id)
      assert principal.type == :human
      assert principal.display_name == "Ada"
    end

    test "the hydrator reads the group member profile and tolerates a hidden profile" do
      config = binding_config()

      assert {:ok, %{"display_name" => "Ada in group"}} =
               Profile.hydrate_author(config, %{
                 "platform_subject" => @user_id,
                 "metadata" => %{"group_id" => @group_id}
               })

      assert {:ok, %{"display_name" => "Ada"}} =
               Profile.hydrate_author(config, %{"platform_subject" => @user_id})

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not found"})
      end)

      assert {:ok, %{}} = Profile.hydrate_author(config, %{"platform_subject" => @user_id})
    end
  end

  describe "actions and outbound" do
    test "renders postback buttons that resolve to the checkpointed action" do
      parent = self()
      %{principal: agent} = agent_fixture()
      %{principal: human} = human_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-action")
      channel_id = "line:#{@bot_user_id}:user:#{@user_id}"

      %{signal: %Signal{} = event} =
        emit_addressed_signal(
          agent.uid,
          "line-action",
          %{
            source_event_id: "event-1",
            provider_conversation_id: channel_id,
            provider_message_id: "m-50",
            channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
            text: "hello",
            explicit: true,
            author:
              Ankole.SignalsFixtures.provider_author_fixture(human.uid, @user_id, %{
                provider: "line-main"
              }),
            provider_time: base_time()
          }
        )

      presentation =
        ReplyPresentation.new(state: "awaiting_input")
        |> Map.merge(%{
          "interaction_status" => "pending",
          "prompt" => "Deploy to production?",
          "actions" => [
            %{
              "type" => "button",
              "id" => "approve",
              "label" => "Approve the deployment right away",
              "interaction_id" => "interaction-1",
              "source_signal_id" => event.id,
              "control_id" => "approve",
              "selected_option_id" => "yes",
              "option_value" => "approved",
              "revision" => 3
            },
            %{"type" => "button", "id" => "off", "label" => "Disabled", "disabled" => true}
          ]
        })

      checkpoint = InteractionState.initialize(%{}, presentation, base_time())

      assert {:ok, _event} =
               PreviewStates.put_checkpoint(event.id, checkpoint)

      assert [template] = Presentation.action_messages(presentation, event.id)
      assert template["template"]["text"] == "Deploy to production?"
      assert [action] = template["template"]["actions"]
      assert action["type"] == "postback"
      assert action["label"] == "Approve the deployme"
      assert String.length(action["label"]) <= 20
      token = action["data"]
      assert byte_size(token) <= 300
      assert String.starts_with?(token, "ln1:")

      assert {:ok, value} =
               ActionToken.resolve(token, agent.uid, "line-action", nil, prefix: "ln1")

      assert value["optionValue"] == "approved"

      # The clarify reply row carries the presentation; sending it pushes the
      # buttons and records the sent message as the event's reply surface.
      card_row =
        Ankole.SignalsFixtures.delivery_fixture!(%{
          agent_uid: agent.uid,
          binding_name: "line-action",
          outbound_key: "ai-reply:clarify-1",
          operation: :reply,
          status: :sent,
          delivery_class: :durable_ai_reply,
          conversation_id: external_conversation_id(channel_id),
          reply_to_provider_message_id: "m-50",
          source_signal_id: event.id,
          created_provider_message_id: "sent-1",
          payload: %{"reply_presentation" => presentation},
          fallback_visible_text: "Deploy to production?"
        })

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:push, Ankole.JSON.decode!(body)})
        Req.Test.json(conn, %{"sentMessages" => [%{"id" => "sent-1", "quoteToken" => "qt-1"}]})
      end)

      assert {:ok, %{created_provider_message_id: "sent-1"}} = Delivery.deliver(card_row)
      assert_received {:push, %{"messages" => [%{"type" => "text"}, %{"type" => "template"}]}}

      assert %Ankole.Conversations.Delivery.PreviewState{provider_message_id: "sent-1"} =
               Ankole.Conversations.Delivery.PreviewStates.get(event.id)

      %{principal: operator} = human_fixture()

      assert {:ok, _identity} =
               MappingRequests.bind_subject(operator.uid, %{
                 provider: "line",
                 external_id: @user_id
               })

      postback = %{
        "type" => "postback",
        "mode" => "active",
        "timestamp" => 1_787_000_002_000,
        "webhookEventId" => "01LINEPOSTBACK000000000000001",
        "deliveryContext" => %{"isRedelivery" => false},
        "source" => user_source(),
        "postback" => %{"data" => token}
      }

      consumer = consumer(agent.uid, "line-action")

      assert {:ok, [%{status: :accepted, signal: action_event}]} =
               Inbound.handle_card_action("postback", envelope(postback), [consumer])

      assert action_event.type == "signal.action.invoked"

      stale = put_in(postback, ["postback", "data"], "ln1:not-a-uuid:0:AAAAAAAAAAA")

      assert {:ok, [%{status: :ignored_stale_action}]} =
               Inbound.handle_card_action("postback", envelope(stale), [consumer])

      stranger = put_in(postback, ["source", "userId"], "U0000000000000000000000000000009")

      assert {:ok, [%{status: :ignored_unmapped_operator}]} =
               Inbound.handle_card_action("postback", envelope(stranger), [consumer])
    end

    test "builds push requests for every declared operation and quotes only in groups" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-out")
      group_channel = "line:#{@bot_user_id}:group:#{@group_id}"
      dm_channel = "line:#{@bot_user_id}:user:#{@user_id}"

      # Unaddressed group chatter is recorded under the default group policy;
      # its mirror keeps the quote token that a later group reply can use.
      assert {:ok, [%{status: :recorded}]} =
               Inbound.handle_message_receive(
                 "message",
                 envelope(message_event(group_source(), text_message("question"))),
                 [consumer(agent.uid, "line-out")]
               )

      %{provider_message_id: quoted_id} = message_snapshot!([])

      base = %Intent{
        agent_uid: agent.uid,
        binding_name: "line-out",
        outbound_key: "out-1",
        operation: :post,
        conversation_id: external_conversation_id(group_channel),
        payload: %{},
        fallback_visible_text: "hello"
      }

      for operation <- [:post, :reply, :divider, :card] do
        intent =
          %{base | operation: operation}
          |> Map.put(:reply_to_provider_message_id, if(operation == :reply, do: quoted_id))

        assert {:ok, [%{index: 0, body: %{"to" => @group_id, "messages" => [_ | _]}}]} =
                 Delivery.requests_for_intent(intent)
      end

      assert {:ok, [%{body: %{"messages" => [reply]}}]} =
               Delivery.requests_for_intent(%{
                 base
                 | operation: :reply,
                   reply_to_provider_message_id: quoted_id
               })

      assert reply["quoteToken"] == "quote-token-1"

      assert {:ok, [%{body: %{"to" => @user_id, "messages" => [dm_reply]}}]} =
               Delivery.requests_for_intent(%{
                 base
                 | operation: :reply,
                   conversation_id: external_conversation_id(dm_channel),
                   reply_to_provider_message_id: quoted_id
               })

      refute Map.has_key?(dm_reply, "quoteToken")

      assert {:error, :unsupported_intent_operation} =
               Delivery.requests_for_intent(%{
                 base
                 | operation: :edit,
                   target_provider_message_id: "1"
               })

      long = String.duplicate("あ", 5_001 * 6)

      assert {:ok, [first, second]} =
               Delivery.requests_for_intent(%{base | fallback_visible_text: long})

      assert length(first.body["messages"]) == 5
      assert length(second.body["messages"]) == 2
      assert Enum.all?(first.body["messages"], &(String.length(&1["text"]) <= 5_000))
      assert Delivery.retry_key(base, 0) == Delivery.retry_key(base, 0)
      assert Delivery.retry_key(base, 0) != Delivery.retry_key(base, 1)

      assert Delivery.retry_key(base, 0) =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end

    test "sends with a retry key, treats an accepted retry as success, and classifies failures" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-send")

      intent = %Intent{
        agent_uid: agent.uid,
        binding_id: Ankole.Signals.get_agent_binding!(agent.uid, "line-send").id,
        binding_name: "line-send",
        outbound_key: "send-1",
        operation: :post,
        conversation_id: external_conversation_id("line:#{@bot_user_id}:user:#{@user_id}"),
        payload: %{},
        fallback_visible_text: "hello"
      }

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:push, Plug.Conn.get_req_header(conn, "x-line-retry-key"), body})
        Req.Test.json(conn, %{"sentMessages" => [%{"id" => "sent-1", "quoteToken" => "qt-1"}]})
      end)

      assert {:ok, %{created_provider_message_id: "sent-1", raw_payload: %{"messages" => [sent]}}} =
               Delivery.deliver(intent)

      assert sent["id"] == "sent-1"
      assert_received {:push, [retry_key], body}
      assert retry_key == Delivery.retry_key(intent, 0)
      assert Ankole.JSON.decode!(body)["to"] == @user_id

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{
          "message" => "The retry key is already accepted",
          "sentMessages" => [%{"id" => "sent-1"}]
        })
      end)

      assert {:ok, %{created_provider_message_id: "sent-1"}} = Delivery.reconcile(intent)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"message" => "You have reached your monthly limit."})
      end)

      assert {:error, {:reply_delivery, :operator_action_required, %{"status" => 429}}} =
               Delivery.deliver(intent)

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"message" => "Too many requests"})
      end)

      assert {:error, {:reply_delivery, :retryable, _detail}} = Delivery.deliver(intent)

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, {:reply_delivery, :retryable, _detail}} = Delivery.deliver(intent)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Authentication failed"})
      end)

      assert {:error, {:reply_delivery, :operator_action_required, _detail}} =
               Delivery.deliver(intent)

      attachment_intent = %{
        intent
        | outbound_key: "send-2",
          payload: %{"attachments" => [%{"name" => "report.pdf"}]}
      }

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "outbound_attachments_not_supported"}}} =
               Delivery.deliver(attachment_intent)
    end
  end

  describe "retry key retention" do
    test "a sending row recovered after the retention window is unknown, inside it reconciles" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-expiry")
      now = DateTime.utc_now(:microsecond)
      channel_id = "line:#{@bot_user_id}:user:#{@user_id}"

      # The chat must exist as a mirrored channel before a reply can route.
      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 envelope(message_event(user_source(), text_message("hello"))),
                 [consumer(agent.uid, "line-expiry")]
               )

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:push, Plug.Conn.get_req_header(conn, "x-line-retry-key")})

        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{
          "message" => "The retry key is already accepted",
          "sentMessages" => [%{"id" => "accepted-earlier"}]
        })
      end)

      stale_row = fn key, age_seconds ->
        started_at = DateTime.add(now, -age_seconds, :second)

        Ankole.SignalsFixtures.delivery_fixture!(%{
          agent_uid: agent.uid,
          binding_name: "line-expiry",
          outbound_key: key,
          operation: :reply,
          status: :pending,
          delivery_class: :durable_ai_reply,
          conversation_id: external_conversation_id(channel_id),
          payload: %{"reply_presentation" => ReplyPresentation.new(state: "completed")},
          fallback_visible_text: "already delivered before shutdown",
          platform_send_started_at: started_at,
          attempt_count: 1,
          inserted_at: started_at,
          updated_at: started_at
        })
      end

      expired = stale_row.("expired-send", 25 * 3600)

      assert {:ok, _outcome} =
               Ankole.Conversations.Delivery.dispatch_by_key(
                 expired.agent_uid,
                 expired.binding_name,
                 expired.outbound_key
               )

      assert %Intent{status: :unknown} =
               Repo.get_by!(Intent, outbound_key: "expired-send")

      refute_received {:push, _key}

      recent = stale_row.("recent-send", 2 * 3600)

      assert {:ok, %{status: :sent, created_provider_message_id: "accepted-earlier"}} =
               Ankole.Conversations.Delivery.dispatch_by_key(
                 recent.agent_uid,
                 recent.binding_name,
                 recent.outbound_key
               )

      assert_received {:push, [_key]}
    end

    test "an aged retry sends only as a first attempt or after the duplicate notice" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-aged")

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:push, conn.request_path})
        Req.Test.json(conn, %{"sentMessages" => [%{"id" => "sent-late"}]})
      end)

      aged = %Intent{
        agent_uid: agent.uid,
        binding_id: Ankole.Signals.get_agent_binding!(agent.uid, "line-aged").id,
        binding_name: "line-aged",
        outbound_key: "aged-1",
        operation: :post,
        conversation_id: external_conversation_id("line:#{@bot_user_id}:user:#{@user_id}"),
        payload: %{},
        fallback_visible_text: "hello",
        attempt_count: 2,
        inserted_at: DateTime.add(DateTime.utc_now(:microsecond), -30 * 3600, :second)
      }

      # The last error says nothing about earlier requests of the same row: a
      # long reply is several pushes, and one of them may have landed.
      for last_error <- [
            %{},
            %{"reason" => %{"code" => "line_api_error"}},
            %{"reason" => %{"code" => "line_api_error", "status" => 502}},
            %{"reason" => %{"code" => "line_api_error", "status" => 429}},
            %{"reason" => %{"code" => "line_api_error", "status" => 401}}
          ] do
        assert :unknown = Delivery.deliver(%{aged | last_error: last_error})
        refute_received {:push, _path}
      end

      flagged = %{aged | possible_duplicate: true}
      assert {:ok, %{created_provider_message_id: "sent-late"}} = Delivery.deliver(flagged)
      assert_received {:push, "/v2/bot/message/push"}

      first_attempt = %{aged | attempt_count: 1}
      assert {:ok, %{created_provider_message_id: "sent-late"}} = Delivery.deliver(first_attempt)
      assert_received {:push, "/v2/bot/message/push"}

      fresh = %{aged | inserted_at: DateTime.utc_now(:microsecond)}
      assert {:ok, %{created_provider_message_id: "sent-late"}} = Delivery.deliver(fresh)
      assert_received {:push, "/v2/bot/message/push"}
    end
  end

  # A download stub that blocks inside the materialization task until the test
  # releases it with `:finish_success` or `:finish_failure`.
  defp blocking_download_fixture(binding_name, message_id) do
    parent = self()
    %{principal: agent} = agent_fixture()
    assert {:ok, _binding} = put_line_binding(agent.uid, binding_name)
    content_path = "/v2/bot/message/#{message_id}/content"

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v2/bot/profile/" <> _user_id ->
          Req.Test.json(conn, %{"displayName" => "Ada", "userId" => @user_id})

        ^content_path ->
          send(parent, {:download_waiting, self()})

          receive do
            :finish_success ->
              conn
              |> Plug.Conn.put_resp_content_type("image/jpeg")
              |> Plug.Conn.send_resp(200, "attachment")

            :finish_failure ->
              conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
          after
            5_000 -> raise "download was not released"
          end
      end
    end)

    photo =
      message_event(user_source(), %{
        "id" => message_id,
        "type" => "image",
        "contentProvider" => %{"type" => "line"}
      })

    %{
      agent: agent,
      fixture: %{photo: photo, consumer: consumer(agent.uid, binding_name)},
      release: fn pid, outcome -> send(pid, outcome) end
    }
  end

  defp complete?(channel_id, provider_message_id) do
    match?(
      %{attachments: [%{"materialization_state" => "complete"}]},
      message_snapshot(
        conversation_id: external_conversation_id(channel_id),
        provider_message_id: provider_message_id
      )
    )
  end

  defp binding_config do
    %{
      "channelId" => @channel_id,
      "channelSecret" => @channel_secret,
      "channelAccessToken" => @access_token
    }
  end

  defp put_line_binding(agent_uid, name, attrs \\ %{}) do
    Ankole.Signals.Bindings.put_binding(
      agent_uid,
      "line",
      name,
      Map.merge(
        %{"config" => binding_config(), "unmatched_sender_policy" => "create_standalone"},
        attrs
      )
    )
  end

  defp consumer(agent_uid, binding_name, config \\ nil, binding_id \\ nil) do
    Inbound.chat_consumer(
      AdapterContext.new(
        binding_id: binding_id || Ankole.Signals.get_agent_binding!(agent_uid, binding_name).id,
        agent_uid: agent_uid,
        binding_name: binding_name,
        adapter: "line",
        user_name: "LINE"
      ),
      config || binding_config()
    )
  end

  defp envelope(event), do: %{"destination" => @bot_user_id, "event" => event}

  defp signed_request(events) do
    payload = %{"destination" => @bot_user_id, "events" => events}
    body = Ankole.JSON.encode!(payload)

    %{
      handler_id: "line",
      instance_id: @channel_id,
      kind: "events",
      query_params: %{},
      body_params: payload,
      raw_body: body,
      headers: %{
        "x-line-signature" => Base.encode64(:crypto.mac(:hmac, :sha256, @channel_secret, body))
      }
    }
  end

  defp user_source, do: %{"type" => "user", "userId" => @user_id}
  defp group_source, do: %{"type" => "group", "groupId" => @group_id, "userId" => @user_id}

  defp message_event(source, message) do
    %{
      "type" => "message",
      "mode" => "active",
      "timestamp" => 1_787_000_000_000,
      "webhookEventId" => "01LINEEVENT#{System.unique_integer([:positive])}",
      "deliveryContext" => %{"isRedelivery" => false},
      "replyToken" => "reply-token",
      "source" => source,
      "message" => message
    }
  end

  defp text_message(text) do
    %{
      "id" => "m-#{System.unique_integer([:positive])}",
      "type" => "text",
      "text" => text,
      "quoteToken" => "quote-token-1"
    }
  end
end
