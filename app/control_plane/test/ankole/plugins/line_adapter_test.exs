defmodule Ankole.Plugins.LineAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import Ankole.Eventually, only: [eventually: 1]

  alias Ankole.Plugins.LineAdapter

  alias Ankole.Plugins.LineAdapter.{
    Config,
    Inbound,
    Outbox,
    Presentation,
    Profile,
    Signature,
    Webhook
  }

  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ReplyActionToken

  alias Ankole.SignalsGateway.{
    ActorEvent,
    AdapterContext,
    Entry,
    OutboxEntry,
    ReplyInteractionState,
    ReplyPresentation
  }

  @channel_id "1650000001"
  @channel_secret "line-channel-secret"
  @access_token "line-long-lived-token"
  @bot_user_id "Ubot00000000000000000000000000000"
  @user_id "U4af4980629000000000000000000001"
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
      refute Map.has_key?(adapter, :reply_preview_module)
      refute Map.has_key?(adapter, :connection_supervisor)

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

      assert handler.contract_id == "signals_gateway.webhook_handler"
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
               SignalsGateway.put_binding(first_agent.uid, "line", "line-one", attrs)

      assert {:error, {:line_channel_already_bound, first_uid, "line-one"}} =
               SignalsGateway.put_binding(second_agent.uid, "line", "line-two", attrs)

      assert first_uid == first_agent.uid
      assert {:ok, _disabled} = SignalsGateway.disable_binding(first_agent.uid, "line-one")

      assert {:ok, _binding} =
               SignalsGateway.put_binding(second_agent.uid, "line", "line-two", attrs)
    end
  end

  describe "signature" do
    test "accepts the Base64 HMAC-SHA256 of the exact bytes and nothing else" do
      body = ~s({"destination":"#{@bot_user_id}","events":[]})
      signature = Signature.sign(body, @channel_secret)

      assert Signature.valid?(body, signature, @channel_secret)
      refute Signature.valid?(body <> " ", signature, @channel_secret)
      refute Signature.valid?(body, signature, "other-secret")
      refute Signature.valid?(body, nil, @channel_secret)
    end
  end

  describe "inbound projection" do
    test "projects direct and group messages with stable identities and mention removal" do
      consumer = consumer("agent-a", "line-main")

      assert {:ok, dm} =
               Inbound.normalize_message_receive(
                 envelope(message_event(user_source(), text_message("hello"))),
                 consumer
               )

      assert dm.explicit
      assert dm.signal_channel_id == "line:#{@bot_user_id}:user:#{@user_id}"
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
      assert group.signal_channel_id == "line:#{@bot_user_id}:group:#{@group_id}"
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

      Repo.insert!(%OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "line-quote",
        outbound_key: "ai-reply:1",
        operation: :post,
        status: :succeeded,
        signal_channel_id: "line:#{@bot_user_id}:group:#{@group_id}",
        created_source_entry_id: "bot-message-1",
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
      assert projected.reply_to_source_entry_id == "bot-message-1"

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
        SignalsGateway.Outbox.commit_outbox(%{
          agent_uid: agent.uid,
          binding_name: "line-group",
          outbound_key: "earlier-bot-post",
          operation: :post,
          signal_channel_id: channel_id,
          payload: %{},
          fallback_visible_text: "earlier bot message"
        })

      assert {:ok, %{status: :succeeded}} =
               SignalsGateway.Outbox.dispatch_outbox_by_key(
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
      refute "command.stop" in Enum.map(Repo.all(ActorEvent), & &1.type)
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
        SignalsGateway.Outbox.commit_outbox(%{
          agent_uid: agent.uid,
          binding_name: "line-split",
          outbound_key: "split-1",
          operation: :post,
          signal_channel_id: "line:#{@bot_user_id}:group:#{@group_id}",
          payload: %{},
          fallback_visible_text: String.duplicate("A", 5_001)
        })

      assert {:ok, %{status: :succeeded, created_source_entry_id: "part-one"}} =
               SignalsGateway.Outbox.dispatch_outbox_by_key(
                 row.agent_uid,
                 row.binding_name,
                 row.outbound_key
               )

      assert %OutboxEntry{payload: %{"line_message_ids" => ["part-one", "part-two"]}} =
               Repo.get_by!(OutboxEntry, outbound_key: "split-1")

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
      consumer = consumer("agent-a", "line-main")

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
      consumer = consumer("agent-a", "line-main")

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
      refute Map.has_key?(attachment, "agent_computer_path")

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

    test "assigns the durable attachment ID before writing an admitted file to user-files" do
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

      route = "line-inbound-attachment-#{System.unique_integer([:positive])}"
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
      assert %Entry{attachments: [pending]} = result.signal_entry
      assert is_integer(pending["attachment_id"])
      refute pending["materialization_state"] == "complete"

      expected_relative = "inbox/#{pending["attachment_id"]}/image-m-photo.jpg"

      assert eventually(fn ->
               entry =
                 Repo.get_by(Entry,
                   signal_channel_id: result.signal_entry.signal_channel_id,
                   source_entry_id: "m-photo"
                 )

               match?(%Entry{attachments: [%{"materialization_state" => "complete"}]}, entry)
             end)

      %Entry{attachments: [attachment]} =
        Repo.get_by(Entry,
          signal_channel_id: result.signal_entry.signal_channel_id,
          source_entry_id: "m-photo"
        )

      assert attachment["attachment_id"] == pending["attachment_id"]
      assert attachment["user_files_relative_path"] == expected_relative
      assert attachment["mimetype"] == "image/jpeg"

      assert attachment["agent_computer_path"] ==
               "/agents/#{agent.uid}/user-files/#{expected_relative}"

      assert_received {:line_request, "/v2/bot/message/m-photo/content"}
      expected_lane = "/user_files/#{agent.uid}/user-files/#{expected_relative}"
      assert_receive {:materialized_attachment_path, ^expected_lane}

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

      assert %Entry{attachments: [kept]} = redelivered.signal_entry
      assert kept["materialization_state"] == "complete"
      assert kept["agent_computer_path"] == attachment["agent_computer_path"]
      assert kept["attachment_id"] == attachment["attachment_id"]
      refute_received {:line_request, "/v2/bot/message/m-photo/content"}

      %Entry{attachments: [stored], metadata: metadata} =
        Repo.get_by(Entry,
          signal_channel_id: result.signal_entry.signal_channel_id,
          source_entry_id: "m-photo"
        )

      assert stored["agent_computer_path"] == attachment["agent_computer_path"]
      assert metadata["attachment_materialization"]["state"] == "complete"
    end

    test "a redelivery during the download fetches again and a late failure cannot lose the file" do
      %{fixture: fixture, release: release} = blocking_download_fixture("line-overlap", "m-slow")
      photo = fixture.photo
      consumer = fixture.consumer

      assert {:ok, [first]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert %Entry{attachments: [pending]} = first.signal_entry
      assert_receive {:download_waiting, first_download}, 2_000

      assert {:ok, [second]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert %Entry{attachments: [reused]} = second.signal_entry
      assert reused["attachment_id"] == pending["attachment_id"]
      assert_receive {:download_waiting, second_download}, 2_000

      release.(first_download, :finish_success)
      channel_id = first.signal_entry.signal_channel_id
      assert eventually(fn -> complete?(channel_id, "m-slow") end)

      # The second fetch fails after the first one wrote the bytes; the entry
      # keeps the readable result under the gateway's merge rule.
      release.(second_download, :finish_failure)
      assert eventually(fn -> not Process.alive?(second_download) end)
      assert complete?(channel_id, "m-slow")

      %Entry{attachments: [attachment]} =
        Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: "m-slow")

      assert attachment["attachment_id"] == pending["attachment_id"]

      assert attachment["agent_computer_path"] =~
               "/inbox/#{pending["attachment_id"]}/image-m-slow.jpg"
    end

    test "a redelivery after the download task died fetches again" do
      %{fixture: fixture, release: release} = blocking_download_fixture("line-dead", "m-dead")
      photo = fixture.photo
      consumer = fixture.consumer

      assert {:ok, [first]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert %Entry{attachments: [pending]} = first.signal_entry
      assert_receive {:download_waiting, dead_download}, 2_000

      Process.exit(dead_download, :kill)
      assert eventually(fn -> not Process.alive?(dead_download) end)

      assert {:ok, [_second]} =
               Inbound.handle_message_receive("message", envelope(photo), [consumer])

      assert_receive {:download_waiting, replacement}, 2_000
      release.(replacement, :finish_success)

      channel_id = first.signal_entry.signal_channel_id
      assert eventually(fn -> complete?(channel_id, "m-dead") end)

      %Entry{attachments: [attachment]} =
        Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: "m-dead")

      assert attachment["attachment_id"] == pending["attachment_id"]
    end

    test "a route moved to another Agent downloads that Agent's own copy" do
      %{fixture: fixture, release: release, agent: first_agent} =
        blocking_download_fixture("line-moved", "m-moved")

      photo = fixture.photo

      assert {:ok, [first]} =
               Inbound.handle_message_receive("message", envelope(photo), [fixture.consumer])

      assert %Entry{attachments: [pending]} = first.signal_entry
      assert_receive {:download_waiting, download}, 2_000
      release.(download, :finish_success)
      channel_id = first.signal_entry.signal_channel_id
      assert eventually(fn -> complete?(channel_id, "m-moved") end)

      %Entry{attachments: [first_copy]} =
        Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: "m-moved")

      assert first_copy["agent_computer_path"] =~ "/agents/#{first_agent.uid}/"

      # The operator moves the route: the old binding is disabled and the
      # channel now belongs to another Agent that holds no copy yet.
      assert {:ok, _disabled} = SignalsGateway.disable_binding(first_agent.uid, "line-moved")
      %{principal: second_agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(second_agent.uid, "line-moved")

      assert {:ok, [_moved]} =
               Inbound.handle_message_receive("message", envelope(photo), [
                 consumer(second_agent.uid, "line-moved")
               ])

      assert_receive {:download_waiting, second_download}, 2_000
      release.(second_download, :finish_success)

      assert eventually(fn -> own_copy?(channel_id, "m-moved", second_agent.uid) end)

      %Entry{attachments: [second_copy]} =
        Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: "m-moved")

      assert second_copy["attachment_id"] == pending["attachment_id"]
      assert second_copy["materialization_state"] == "complete"
    end
  end

  describe "webhook dispatch" do
    test "verifies the signature, stores each event once, and answers the Verify probe" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-main")

      request = signed_request([message_event(user_source(), text_message("hello"))])

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(request)
      assert Repo.aggregate(Entry, :count) == 1

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(request)
      assert Repo.aggregate(Entry, :count) == 1

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request([]))

      forged = %{
        request
        | headers: %{"x-line-signature" => Signature.sign("{}", @channel_secret)}
      }

      assert {:ok, %{status: 401}} = Webhook.handle_webhook(forged)

      assert {:ok, %{status: 404}} = Webhook.handle_webhook(%{request | instance_id: "999"})
      assert Repo.aggregate(Entry, :count) == 1
    end

    test "an unsend event removes the mirrored message" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-main")

      event = message_event(user_source(), text_message("delete me"))
      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request([event]))
      assert %Entry{} = Repo.get_by(Entry, source_entry_id: event["message"]["id"])

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
      assert is_nil(Repo.get_by(Entry, source_entry_id: event["message"]["id"]))
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
      assert Repo.aggregate(Entry, :count) == 0

      assert %OutboxEntry{operation: :reply, fallback_visible_text: notice} =
               Repo.one!(OutboxEntry)

      assert notice == Ankole.I18n.t("signals_gateway.reply.unmapped_sender")

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
      human_fixture(%{uid: "human-a"})
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-action")
      channel_id = "line:#{@bot_user_id}:user:#{@user_id}"

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(
          agent.uid,
          "line-action",
          %{
            source_event_id: "event-1",
            signal_channel_id: channel_id,
            source_entry_id: "m-50",
            channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
            text: "hello",
            explicit: true,
            author: %{principal_uid: "human-a", id: @user_id},
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
              "source_actor_event_id" => event.id,
              "control_id" => "approve",
              "selected_option_id" => "yes",
              "option_value" => "approved",
              "revision" => 3
            },
            %{"type" => "button", "id" => "off", "label" => "Disabled", "disabled" => true}
          ]
        })

      checkpoint = ReplyInteractionState.initialize(%{}, presentation, base_time())
      assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)

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
               ReplyActionToken.resolve(token, agent.uid, "line-action", nil, prefix: "ln1")

      assert value["optionValue"] == "approved"

      # The clarify reply row carries the presentation; sending it pushes the
      # buttons and records the sent message as the event's reply surface.
      card_row =
        Repo.insert!(%OutboxEntry{
          agent_uid: agent.uid,
          binding_name: "line-action",
          outbound_key: "ai-reply:clarify-1",
          operation: :reply,
          status: :succeeded,
          delivery_class: :durable_ai_reply,
          signal_channel_id: channel_id,
          reply_to_source_entry_id: "m-50",
          source_actor_event_id: event.id,
          created_source_entry_id: "sent-1",
          payload: %{"reply_presentation" => presentation},
          fallback_visible_text: "Deploy to production?"
        })

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:push, Ankole.JSON.decode!(body)})
        Req.Test.json(conn, %{"sentMessages" => [%{"id" => "sent-1", "quoteToken" => "qt-1"}]})
      end)

      assert {:ok, %{created_source_entry_id: "sent-1"}} = Outbox.send(card_row)
      assert_received {:push, %{"messages" => [%{"type" => "text"}, %{"type" => "template"}]}}

      assert %ActorEvent{reply_preview_source_entry_id: "sent-1"} =
               Repo.get!(ActorEvent, event.id)

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

      assert {:ok, [%{status: :accepted, actor_event: action_event}]} =
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

      %Entry{source_entry_id: quoted_id} = Repo.one!(Entry)

      base = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "line-out",
        outbound_key: "out-1",
        operation: :post,
        signal_channel_id: group_channel,
        payload: %{},
        fallback_visible_text: "hello"
      }

      for operation <- [:post, :reply, :divider, :card] do
        outbox =
          %{base | operation: operation}
          |> Map.put(:reply_to_source_entry_id, if(operation == :reply, do: quoted_id))

        assert {:ok, [%{index: 0, body: %{"to" => @group_id, "messages" => [_ | _]}}]} =
                 Outbox.requests_for_outbox(outbox)
      end

      assert {:ok, [%{body: %{"messages" => [reply]}}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :reply,
                   reply_to_source_entry_id: quoted_id
               })

      assert reply["quoteToken"] == "quote-token-1"

      assert {:ok, [%{body: %{"to" => @user_id, "messages" => [dm_reply]}}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :reply,
                   signal_channel_id: dm_channel,
                   reply_to_source_entry_id: quoted_id
               })

      refute Map.has_key?(dm_reply, "quoteToken")

      assert {:error, :unsupported_outbox_operation} =
               Outbox.requests_for_outbox(%{base | operation: :edit, target_source_entry_id: "1"})

      long = String.duplicate("あ", 5_001 * 6)

      assert {:ok, [first, second]} =
               Outbox.requests_for_outbox(%{base | fallback_visible_text: long})

      assert length(first.body["messages"]) == 5
      assert length(second.body["messages"]) == 2
      assert Enum.all?(first.body["messages"], &(String.length(&1["text"]) <= 5_000))
      assert Outbox.retry_key(base, 0) == Outbox.retry_key(base, 0)
      assert Outbox.retry_key(base, 0) != Outbox.retry_key(base, 1)

      assert Outbox.retry_key(base, 0) =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end

    test "sends with a retry key, treats an accepted retry as success, and classifies failures" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_line_binding(agent.uid, "line-send")

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "line-send",
        outbound_key: "send-1",
        operation: :post,
        signal_channel_id: "line:#{@bot_user_id}:user:#{@user_id}",
        payload: %{},
        fallback_visible_text: "hello"
      }

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:push, Plug.Conn.get_req_header(conn, "x-line-retry-key"), body})
        Req.Test.json(conn, %{"sentMessages" => [%{"id" => "sent-1", "quoteToken" => "qt-1"}]})
      end)

      assert {:ok, %{created_source_entry_id: "sent-1", raw_payload: %{"messages" => [sent]}}} =
               Outbox.send(outbox)

      assert sent["id"] == "sent-1"
      assert_received {:push, [retry_key], body}
      assert retry_key == Outbox.retry_key(outbox, 0)
      assert Ankole.JSON.decode!(body)["to"] == @user_id

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{
          "message" => "The retry key is already accepted",
          "sentMessages" => [%{"id" => "sent-1"}]
        })
      end)

      assert {:ok, %{created_source_entry_id: "sent-1"}} = Outbox.reconcile(outbox)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"message" => "You have reached your monthly limit."})
      end)

      assert {:error, {:reply_delivery, :operator_action_required, %{"status" => 429}}} =
               Outbox.send(outbox)

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"message" => "Too many requests"})
      end)

      assert {:error, {:reply_delivery, :retryable, _detail}} = Outbox.send(outbox)

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, {:reply_delivery, :retryable, _detail}} = Outbox.send(outbox)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Authentication failed"})
      end)

      assert {:error, {:reply_delivery, :operator_action_required, _detail}} = Outbox.send(outbox)

      attachment_outbox = %{
        outbox
        | outbound_key: "send-2",
          payload: %{"attachments" => [%{"name" => "report.pdf"}]}
      }

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "outbound_attachments_not_supported"}}} =
               Outbox.send(attachment_outbox)
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

        Repo.insert!(%OutboxEntry{
          agent_uid: agent.uid,
          binding_name: "line-expiry",
          outbound_key: key,
          operation: :reply,
          status: :sending,
          delivery_class: :durable_ai_reply,
          signal_channel_id: channel_id,
          payload: %{"reply_presentation" => ReplyPresentation.new(state: "completed")},
          fallback_visible_text: "already delivered before shutdown",
          platform_send_started_at: started_at,
          last_attempted_at: started_at,
          attempt_count: 1,
          inserted_at: started_at,
          updated_at: started_at
        })
      end

      expired = stale_row.("expired-send", 25 * 3600)

      assert {:ok, _outcome} =
               SignalsGateway.Outbox.dispatch_outbox_by_key(
                 expired.agent_uid,
                 expired.binding_name,
                 expired.outbound_key
               )

      assert %OutboxEntry{status: :unknown_after_send} =
               Repo.get_by!(OutboxEntry, outbound_key: "expired-send")

      refute_received {:push, _key}

      recent = stale_row.("recent-send", 2 * 3600)

      assert {:ok, %{status: :succeeded, created_source_entry_id: "accepted-earlier"}} =
               SignalsGateway.Outbox.dispatch_outbox_by_key(
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

      aged = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "line-aged",
        outbound_key: "aged-1",
        operation: :post,
        signal_channel_id: "line:#{@bot_user_id}:user:#{@user_id}",
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
        assert :unknown = Outbox.send(%{aged | last_error: last_error})
        refute_received {:push, _path}
      end

      flagged = %{aged | recovery_state: %{"possible_duplicate" => true}}
      assert {:ok, %{created_source_entry_id: "sent-late"}} = Outbox.send(flagged)
      assert_received {:push, "/v2/bot/message/push"}

      first_attempt = %{aged | attempt_count: 1}
      assert {:ok, %{created_source_entry_id: "sent-late"}} = Outbox.send(first_attempt)
      assert_received {:push, "/v2/bot/message/push"}

      fresh = %{aged | inserted_at: DateTime.utc_now(:microsecond)}
      assert {:ok, %{created_source_entry_id: "sent-late"}} = Outbox.send(fresh)
      assert_received {:push, "/v2/bot/message/push"}
    end
  end

  # A download stub that blocks inside the materialization task until the test
  # releases it with `:finish_success` or `:finish_failure`, plus a fake worker
  # that accepts the user-files write for any Agent.
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

    route = "#{binding_name}-#{System.unique_integer([:positive])}"
    worker = insert_ready_worker!(route)
    route_auth = %{route: route, worker_id: worker.worker_id}
    {:ok, stored_path} = Agent.start_link(fn -> nil end)

    :ok =
      Broker.register_local_worker(route, fn
        {:file_transfer_lane, [protocol, "WRITE_OPEN", transfer_id, path, _size]} ->
          Agent.update(stored_path, fn _current -> path end)

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
          FileTransferLane.handle_worker_frame(route_auth, [
            protocol,
            "WRITE_COMMITTED",
            transfer_id,
            Agent.get(stored_path, & &1),
            u64(byte_size("attachment")),
            "8db84f6b892cfa6bdad930c907ecb808"
          ])
      end)

    on_exit(fn -> Broker.unregister_local_worker(route) end)

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

  defp complete?(channel_id, source_entry_id) do
    match?(
      %Entry{attachments: [%{"materialization_state" => "complete"}]},
      Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: source_entry_id)
    )
  end

  defp own_copy?(channel_id, source_entry_id, agent_uid) do
    case Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: source_entry_id) do
      %Entry{attachments: [%{"agent_computer_path" => path}]} when is_binary(path) ->
        String.contains?(path, "/agents/#{agent_uid}/")

      _other ->
        false
    end
  end

  defp binding_config do
    %{
      "channelId" => @channel_id,
      "channelSecret" => @channel_secret,
      "channelAccessToken" => @access_token
    }
  end

  defp put_line_binding(agent_uid, name, attrs \\ %{}) do
    SignalsGateway.put_binding(
      agent_uid,
      "line",
      name,
      Map.merge(
        %{"config" => binding_config(), "unmatched_sender_policy" => "create_standalone"},
        attrs
      )
    )
  end

  defp consumer(agent_uid, binding_name, config \\ nil) do
    Inbound.chat_consumer(
      AdapterContext.new(
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
      headers: %{"x-line-signature" => Signature.sign(body, @channel_secret)}
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

  defp insert_ready_worker!(route) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: "line-worker-#{System.unique_integer([:positive])}",
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

  defp u64(value), do: <<value::unsigned-big-integer-size(64)>>
end
