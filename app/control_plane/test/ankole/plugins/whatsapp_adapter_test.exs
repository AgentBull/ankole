defmodule Ankole.Plugins.WhatsAppAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import Ankole.Eventually, only: [eventually: 1]

  alias Ankole.Plugins.WhatsAppAdapter

  alias Ankole.Plugins.WhatsAppAdapter.{
    Config,
    Inbound,
    Outbox,
    Presentation,
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

  alias Ankole.SignalsGateway.{
    ActorEvent,
    AdapterContext,
    Channel,
    Entry,
    OutboxEntry,
    ReplyInteractionState,
    ReplyPresentation
  }

  @app_id "1009900000001"
  @app_secret "whatsapp-app-secret"
  @verify_token "whatsapp-verify-token"
  @phone_number_id "1500000000001"
  @other_phone_number_id "1500000000002"
  @access_token "whatsapp-system-user-token"
  @wa_id "14155552671"
  @channel_id "whatsapp:1500000000001:14155552671"

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [base_url: "https://graph.test", plug: {Req.Test, __MODULE__}]
    )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.sent-1"}]})
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
      assert WhatsAppAdapter.plugin_id() == "whatsapp-adapter"
      assert [adapter, handler] = WhatsAppAdapter.adapter_declarations()
      assert adapter.id == "whatsapp"
      assert adapter.adapter_category == "consumer_im"
      refute Map.has_key?(adapter, :author_hydrator)
      refute Map.has_key?(adapter, :reply_preview_module)
      refute Map.has_key?(adapter, :connection_supervisor)
      assert adapter.supported_group_message_modes == ["addressed_only"]
      assert adapter.inbound_capabilities == ["entry_receive", "action_event"]
      assert adapter.outbound_capabilities == ["post_entry", "reply_entry", "divider", "card"]

      assert Enum.map(adapter.fields, & &1.path) == [
               "appId",
               "appSecret",
               "verifyToken",
               "phoneNumberId",
               "accessToken"
             ]

      assert Enum.map(adapter.fields, & &1.encrypted) == [false, true, true, false, true]

      assert handler.contract_id == "signals_gateway.webhook_handler"
      assert handler.id == "whatsapp"
      assert handler.module == Webhook
      assert handler.kinds == ["events"]
    end

    test "keeps two Agents' same-name bindings on distinct config keys" do
      assert Config.binding_config_key("agent-a", "wa-main") !=
               Config.binding_config_key("agent-b", "wa-main")
    end

    test "validates both numeric ids and the three secrets and redacts them from inspection" do
      assert {:ok, config} = Config.validate_binding_config(binding_config())
      assert config["appId"] == @app_id

      assert {:error, :invalid_whatsapp_app_id} =
               Config.validate_binding_config(Map.put(binding_config(), "appId", "abc"))

      assert {:error, :invalid_whatsapp_phone_number_id} =
               Config.validate_binding_config(Map.put(binding_config(), "phoneNumberId", "+1"))

      assert {:error, _reason} =
               Config.validate_binding_config(Map.delete(binding_config(), "verifyToken"))

      runtime = %Config.Runtime{
        app_id: @app_id,
        app_secret: @app_secret,
        verify_token: @verify_token,
        phone_number_id: @phone_number_id,
        access_token: @access_token
      }

      rendered = inspect(runtime)
      assert rendered =~ @app_id
      assert rendered =~ @phone_number_id
      refute rendered =~ @app_secret
      refute rendered =~ @verify_token
      refute rendered =~ @access_token
      refute inspect(Config.client(config)) =~ @access_token
    end

    test "one phone number can belong to only one enabled binding" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()
      attrs = %{"config" => binding_config(), "group_message_mode" => "addressed_only"}

      assert {:ok, _binding} =
               SignalsGateway.put_binding(first_agent.uid, "whatsapp", "wa-one", attrs)

      assert {:error, {:whatsapp_phone_number_already_bound, first_uid, "wa-one"}} =
               SignalsGateway.put_binding(second_agent.uid, "whatsapp", "wa-two", attrs)

      assert first_uid == first_agent.uid
      assert {:ok, _disabled} = SignalsGateway.disable_binding(first_agent.uid, "wa-one")

      assert {:ok, _binding} =
               SignalsGateway.put_binding(second_agent.uid, "whatsapp", "wa-two", attrs)
    end

    test "enabled bindings that share one App must share its secret and verify token" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(first_agent.uid, "whatsapp", "wa-one", %{
                 "config" => binding_config(),
                 "group_message_mode" => "addressed_only"
               })

      assert {:error, {:whatsapp_app_credentials_mismatch, _uid, "wa-one"}} =
               SignalsGateway.put_binding(second_agent.uid, "whatsapp", "wa-two", %{
                 "config" =>
                   binding_config()
                   |> Map.put("phoneNumberId", @other_phone_number_id)
                   |> Map.put("appSecret", "another-app-secret"),
                 "group_message_mode" => "addressed_only"
               })

      assert {:error, {:whatsapp_app_credentials_mismatch, _uid, "wa-one"}} =
               SignalsGateway.put_binding(second_agent.uid, "whatsapp", "wa-two", %{
                 "config" =>
                   binding_config()
                   |> Map.put("phoneNumberId", @other_phone_number_id)
                   |> Map.put("verifyToken", "another-verify-token"),
                 "group_message_mode" => "addressed_only"
               })

      assert {:ok, _binding} =
               SignalsGateway.put_binding(second_agent.uid, "whatsapp", "wa-two", %{
                 "config" => Map.put(binding_config(), "phoneNumberId", @other_phone_number_id),
                 "group_message_mode" => "addressed_only"
               })
    end
  end

  describe "signature" do
    test "accepts the hex HMAC-SHA256 of the exact bytes and nothing else" do
      body = ~s({"object":"whatsapp_business_account","entry":[]})
      signature = Signature.sign(body, @app_secret)

      assert String.starts_with?(signature, "sha256=")
      assert Signature.valid?(body, signature, @app_secret)
      refute Signature.valid?(body <> " ", signature, @app_secret)
      refute Signature.valid?(body, signature, "other-secret")
      refute Signature.valid?(body, nil, @app_secret)
    end
  end

  describe "webhook dispatch" do
    test "answers the subscription challenge only for the stored verify token" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-verify")

      assert {:ok, %{status: 200, body: "challenge-1", content_type: "text/plain"}} =
               Webhook.handle_webhook(verification_request(@verify_token, "subscribe"))

      assert {:ok, %{status: 403}} =
               Webhook.handle_webhook(verification_request("wrong-token", "subscribe"))

      assert {:ok, %{status: 403}} =
               Webhook.handle_webhook(verification_request(@verify_token, "unsubscribe"))

      unknown_app = %{verification_request(@verify_token, "subscribe") | instance_id: "999"}
      assert {:ok, %{status: 404}} = Webhook.handle_webhook(unknown_app)
    end

    test "verifies the signature, stores each message once, and refuses an unknown App" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-main")

      request = signed_request(value([text_message("hello")]))

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(request)
      assert Repo.aggregate(Entry, :count) == 1

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(request)
      assert Repo.aggregate(Entry, :count) == 1

      forged = %{request | headers: %{"x-hub-signature-256" => Signature.sign("{}", @app_secret)}}
      assert {:ok, %{status: 401}} = Webhook.handle_webhook(forged)

      assert {:ok, %{status: 404}} = Webhook.handle_webhook(%{request | instance_id: "999"})
      assert Repo.aggregate(Entry, :count) == 1
    end

    test "routes each change by phone number ID and ignores a number it does not serve" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(first_agent.uid, "wa-first")

      assert {:ok, _binding} =
               put_whatsapp_binding(second_agent.uid, "wa-second", %{
                 "config" => Map.put(binding_config(), "phoneNumberId", @other_phone_number_id)
               })

      second =
        [text_message("for the second number")]
        |> value()
        |> put_in(["metadata", "phone_number_id"], @other_phone_number_id)

      unknown =
        [text_message("for nobody")]
        |> value()
        |> put_in(["metadata", "phone_number_id"], "1500000000009")

      assert {:ok, %{status: 200}} =
               Webhook.handle_webhook(signed_request(value([text_message("for the first")])))

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request(second))
      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request(unknown))

      channels = Entry |> Repo.all() |> Enum.map(& &1.signal_channel_id) |> Enum.sort()

      assert channels == [
               "whatsapp:#{@phone_number_id}:#{@wa_id}",
               "whatsapp:#{@other_phone_number_id}:#{@wa_id}"
             ]
    end

    test "a delivery status writes nothing" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-status")

      statuses =
        value([])
        |> Map.delete("messages")
        |> Map.put("statuses", [
          %{
            "id" => "wamid.sent-1",
            "status" => "failed",
            "errors" => [%{"code" => 131_047, "title" => "Re-engagement message"}]
          }
        ])

      assert {:ok, %{status: 200}} = Webhook.handle_webhook(signed_request(statuses))
      assert Repo.aggregate(Entry, :count) == 0
    end
  end

  describe "inbound projection" do
    test "projects text, captions, locations, documents, and stable channel identities" do
      consumer = consumer("agent-a", "wa-main")

      assert {:ok, text} =
               Inbound.normalize_message_receive(envelope(text_message("hello")), consumer)

      assert text.explicit
      assert text.signal_channel_id == @channel_id
      assert text.channel.kind == :im_dm
      assert text.channel.reply_mode == :entry
      assert is_nil(text.provider_thread_id)
      assert text.text == "hello"
      assert text.author["provider"] == "whatsapp"
      assert text.author["platform_subject"] == @wa_id
      assert text.author["display_name"] == "Ada"
      assert text.author["mobile"] == "+#{@wa_id}"
      refute Map.has_key?(text.author, "email")

      quoted =
        text_message("what about this?")
        |> Map.put("context", %{"from" => @phone_number_id, "id" => "wamid.bot-1"})

      assert {:ok, %{reply_to_source_entry_id: "wamid.bot-1"}} =
               Inbound.normalize_message_receive(envelope(quoted), consumer)

      image =
        media_message("image", %{
          "id" => "media-1",
          "mime_type" => "image/jpeg",
          "caption" => "the chart"
        })

      assert {:ok, projected_image} = Inbound.normalize_message_receive(envelope(image), consumer)
      assert projected_image.text == "the chart"
      assert [%{"provider_file_id" => "media-1", "kind" => "image"}] = projected_image.attachments

      document =
        media_message("document", %{
          "id" => "media-2",
          "mime_type" => "application/pdf",
          "filename" => "report.pdf"
        })

      assert {:ok, %{attachments: [attachment], text: nil}} =
               Inbound.normalize_message_receive(envelope(document), consumer)

      assert attachment["name"] == "report.pdf"
      assert attachment["mimetype"] == "application/pdf"

      location =
        message(%{
          "type" => "location",
          "location" => %{
            "latitude" => 37.44,
            "longitude" => -122.16,
            "name" => "Office",
            "address" => "1 Main Street"
          }
        })

      assert {:ok, %{text: location_text, attachments: []}} =
               Inbound.normalize_message_receive(envelope(location), consumer)

      assert location_text == "Location: Office 1 Main Street 37.44, -122.16"

      contacts =
        message(%{
          "type" => "contacts",
          "contacts" => [%{"name" => %{"formatted_name" => "Grace Hopper"}}]
        })

      assert {:ok, %{text: "Contacts: Grace Hopper"}} =
               Inbound.normalize_message_receive(envelope(contacts), consumer)
    end

    test "ignores group messages, unsupported types, and a message with nothing in it" do
      consumer = consumer("agent-a", "wa-main")
      grouped = Map.put(text_message("hello group"), "group_id", "group-1")

      assert {:ignore, :group_message} =
               Inbound.normalize_message_receive(envelope(grouped), consumer)

      for type <- ["reaction", "unsupported", "system", "request_welcome", "order", "poll"] do
        assert {:ignore, :unsupported_message_type} =
                 Inbound.normalize_message_receive(envelope(message(%{"type" => type})), consumer)
      end

      assert {:ignore, :empty_message} =
               Inbound.normalize_message_receive(
                 envelope(message(%{"type" => "text", "text" => %{"body" => "   "}})),
                 consumer
               )
    end

    test "a template quick reply enters as plain text" do
      consumer = consumer("agent-a", "wa-main")

      button =
        message(%{
          "type" => "button",
          "button" => %{"payload" => "opt-in", "text" => "Yes, continue"}
        })

      assert {:ok, %{text: "Yes, continue", attachments: []}} =
               Inbound.normalize_message_receive(envelope(button), consumer)
    end
  end

  describe "identity admission" do
    test "manual review holds an unknown sender until an administrator maps it" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               put_whatsapp_binding(agent.uid, "wa-review", %{
                 "unmatched_sender_policy" => "manual_review"
               })

      consumer = consumer(agent.uid, "wa-review")

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               Inbound.handle_message_receive("message", envelope(text_message("hello")), [
                 consumer
               ])

      assert [request] = MappingRequests.list_requests()
      assert request.provider == "whatsapp"
      assert request.external_id == @wa_id
      assert request.display_name == "Ada"
      assert request.mobile == "+#{@wa_id}"
      assert Repo.aggregate(Entry, :count) == 0

      assert %OutboxEntry{operation: :reply, fallback_visible_text: notice} =
               Repo.one!(OutboxEntry)

      assert notice == Ankole.I18n.t("signals_gateway.reply.unmapped_sender")

      %{principal: human} = human_fixture()
      assert {:ok, _mapping} = MappingRequests.bind_request(request.id, human.uid)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", envelope(text_message("resend")), [
                 consumer
               ])

      assert {:ok, matched} = Principals.resolve_platform_subject("whatsapp", @wa_id)
      assert matched.uid == human.uid
    end

    test "a Principal whose mobile is that number is matched without any mapping" do
      %{principal: agent} = agent_fixture()
      %{principal: human} = human_fixture(%{mobile: "+#{@wa_id}"})

      assert {:ok, _binding} =
               put_whatsapp_binding(agent.uid, "wa-mobile", %{
                 "unmatched_sender_policy" => "manual_review"
               })

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", envelope(text_message("hello")), [
                 consumer(agent.uid, "wa-mobile")
               ])

      assert MappingRequests.list_requests() == []
      assert {:ok, matched} = Principals.resolve_platform_subject("whatsapp", @wa_id)
      assert matched.uid == human.uid
    end

    test "create_standalone names the new account from the webhook contact profile" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-standalone")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", envelope(text_message("hello")), [
                 consumer(agent.uid, "wa-standalone")
               ])

      assert {:ok, principal} = Principals.resolve_platform_subject("whatsapp", @wa_id)
      assert principal.type == :human
      assert principal.display_name == "Ada"
    end
  end

  describe "attachment materialization" do
    test "assigns the durable attachment ID before writing an admitted file to user-files" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-media")
      register_file_writer!("wa-media")

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:whatsapp_request, conn.request_path})

        if String.ends_with?(conn.request_path, "/media-photo") do
          Req.Test.json(conn, %{
            "id" => "media-photo",
            "url" => "https://graph.test/media/media-photo/bytes",
            "mime_type" => "image/jpeg",
            "file_size" => 10
          })
        else
          conn
          |> Plug.Conn.put_resp_content_type("image/jpeg")
          |> Plug.Conn.send_resp(200, "attachment")
        end
      end)

      photo = media_message("image", %{"id" => "media-photo", "mime_type" => "image/jpeg"})

      assert {:ok, [result]} =
               Inbound.handle_message_receive("message", envelope(photo), [
                 consumer(agent.uid, "wa-media")
               ])

      # The webhook answer carries the pending observation; the download runs
      # after it, so the durable ID exists before any bytes move.
      assert %Entry{attachments: [pending]} = result.signal_entry
      assert is_integer(pending["attachment_id"])
      refute pending["materialization_state"] == "complete"

      expected_relative = "inbox/#{pending["attachment_id"]}/image-media-photo.jpg"
      assert eventually(fn -> complete?(@channel_id, photo["id"]) end)

      %Entry{attachments: [attachment]} =
        Repo.get_by(Entry, signal_channel_id: @channel_id, source_entry_id: photo["id"])

      assert attachment["attachment_id"] == pending["attachment_id"]
      assert attachment["user_files_relative_path"] == expected_relative
      assert attachment["mimetype"] == "image/jpeg"

      assert attachment["agent_computer_path"] ==
               "/agents/#{agent.uid}/user-files/#{expected_relative}"

      assert_received {:whatsapp_request, "/media/media-photo/bytes"}
      expected_lane = "/user_files/#{agent.uid}/user-files/#{expected_relative}"
      assert_receive {:materialized_attachment_path, ^expected_lane}

      # Meta delivers the same change again after a non-200 answer. The
      # completed download stays and no second fetch runs.
      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:whatsapp_request, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      assert {:ok, [redelivered]} =
               Inbound.handle_message_receive("message", envelope(photo), [
                 consumer(agent.uid, "wa-media")
               ])

      assert %Entry{attachments: [kept]} = redelivered.signal_entry
      assert kept["materialization_state"] == "complete"
      assert kept["agent_computer_path"] == attachment["agent_computer_path"]
      refute_received {:whatsapp_request, "/media/media-photo/bytes"}
    end

    test "a file over the download budget keeps the provider fact and no local path" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-large")

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "id" => "media-large",
          "url" => "https://graph.test/media/media-large/bytes",
          "mime_type" => "application/pdf",
          "file_size" => 26 * 1024 * 1024
        })
      end)

      large =
        media_message("document", %{
          "id" => "media-large",
          "mime_type" => "application/pdf",
          "filename" => "archive.pdf"
        })

      assert {:ok, [_result]} =
               Inbound.handle_message_receive("message", envelope(large), [
                 consumer(agent.uid, "wa-large")
               ])

      assert eventually(fn -> restricted?(@channel_id, large["id"]) end)

      %Entry{attachments: [attachment]} =
        Repo.get_by(Entry, signal_channel_id: @channel_id, source_entry_id: large["id"])

      assert attachment["restriction"] =~ "25 MB"
      refute Map.has_key?(attachment, "agent_computer_path")
    end

    test "a materialization task that cannot start fails the request so Meta delivers again" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-no-task")

      photo = media_message("image", %{"id" => "media-blocked", "mime_type" => "image/jpeg"})
      supervisor = Ankole.Plugins.WhatsAppAdapter.MaterializationTaskSupervisor
      pid = Process.whereis(supervisor)
      assert is_pid(pid)
      Process.unregister(supervisor)

      try do
        assert catch_exit(
                 Inbound.handle_message_receive("message", envelope(photo), [
                   consumer(agent.uid, "wa-no-task")
                 ])
               )
      after
        Process.register(pid, supervisor)
      end

      # The pending observation is already durable, so the redelivery fetches
      # the bytes instead of losing them.
      assert %Entry{attachments: [pending], metadata: metadata} =
               Repo.get_by(Entry, signal_channel_id: @channel_id, source_entry_id: photo["id"])

      assert metadata["attachment_materialization"]["state"] == "pending"
      assert is_integer(pending["attachment_id"])
      refute Map.has_key?(pending, "agent_computer_path")
    end
  end

  describe "interactive actions" do
    test "a button reply resolves to the checkpointed action and names the card message" do
      parent = self()
      %{agent: agent, event: event, presentation: presentation} = clarification("wa-buttons", 2)

      assert %{"interactive" => %{"type" => "button"} = interactive} =
               Presentation.action_message(presentation, event.id, "Deploy to production?")

      assert_valid_interactive!(Presentation.action_message(presentation, event.id, "Deploy?"))
      assert [first_button, second_button] = interactive["action"]["buttons"]
      assert first_button["type"] == "reply"

      # The labels of this presentation are identical up to the title limit, so
      # only the ordinals keep the titles apart and the message acceptable.
      assert first_button["reply"]["title"] == "1. Approve the deplo"
      assert second_button["reply"]["title"] == "2. Approve the deplo"

      # A label the title cannot hold continues under the prompt, so the user
      # still reads what each number means.
      assert interactive["body"]["text"] =~ "Deploy to production?"
      assert interactive["body"]["text"] =~ "1. Approve the deployment option 1"
      assert interactive["body"]["text"] =~ "2. Approve the deployment option 2"

      token = first_button["reply"]["id"]
      assert byte_size(token) <= 256
      assert String.starts_with?(token, "wa1:")

      # Each message of the reply gets its own id, so a surface taken from the
      # wrong message cannot pass by accident.
      stub_typed_sends(parent)

      assert {:ok, %{created_source_entry_id: "wamid.text-1", payload: payload}} =
               Outbox.send(card_row(agent, "wa-buttons", event, presentation))

      assert payload["whatsapp_message_ids"] == ["wamid.text-1", "wamid.card-1"]
      assert_received {:sent, %{"type" => "text"}}
      assert_received {:sent, %{"type" => "interactive"}}

      # The buttons live on the interactive message, so that message is the
      # surface, not the text chunk the gateway records as the created entry.
      assert %ActorEvent{reply_preview_source_entry_id: "wamid.card-1"} =
               Repo.get!(ActorEvent, event.id)

      bind_operator!()
      consumer = consumer(agent.uid, "wa-buttons")

      assert {:ok, [%{status: :accepted, actor_event: action_event}]} =
               Inbound.handle_card_action(
                 "interactive",
                 envelope(interactive_message("button_reply", token, "wamid.card-1")),
                 [consumer]
               )

      assert action_event.type == "signal.action.invoked"

      stale = interactive_message("button_reply", "wa1:not-a-uuid:0:AAAAAAAAAAA", "wamid.card-1")

      assert {:ok, [%{status: :ignored_stale_action}]} =
               Inbound.handle_card_action("interactive", envelope(stale), [consumer])

      text_chunk_surface = interactive_message("button_reply", token, "wamid.text-1")

      assert {:ok, [%{status: :ignored_stale_action}]} =
               Inbound.handle_card_action("interactive", envelope(text_chunk_surface), [consumer])

      unrelated_surface = interactive_message("button_reply", token, "wamid.other-card")

      assert {:ok, [%{status: :ignored_stale_action}]} =
               Inbound.handle_card_action("interactive", envelope(unrelated_surface), [consumer])

      stranger =
        put_in(
          interactive_message("button_reply", token, "wamid.card-1"),
          ["from"],
          "14155559999"
        )

      assert {:ok, [%{status: :ignored_unmapped_operator}]} =
               Inbound.handle_card_action("interactive", envelope(stranger), [consumer])
    end

    test "a list reply resolves to the checkpointed action" do
      parent = self()
      %{agent: agent, event: event, presentation: presentation} = clarification("wa-list", 5)

      assert %{"interactive" => %{"type" => "list"} = list} =
               Presentation.action_message(presentation, event.id, "Deploy to production?")

      assert_valid_interactive!(Presentation.action_message(presentation, event.id, "Deploy?"))
      assert [%{"rows" => rows}] = list["action"]["sections"]
      assert length(rows) == 5
      assert Enum.map(rows, & &1["title"]) |> Enum.uniq() |> length() == 5
      assert List.first(rows)["title"] == "1. Approve the deploymen"

      # A cut title keeps its full text in the row description.
      assert List.first(rows)["description"] == "Approve the deployment option 1"
      assert list["action"]["button"] == Ankole.I18n.t("signals_gateway.reply.choose_option")

      stub_typed_sends(parent)

      assert {:ok, %{created_source_entry_id: "wamid.text-1"}} =
               Outbox.send(card_row(agent, "wa-list", event, presentation))

      assert_received {:sent, %{"type" => "interactive"}}

      assert %ActorEvent{reply_preview_source_entry_id: "wamid.card-1"} =
               Repo.get!(ActorEvent, event.id)

      bind_operator!()
      token = rows |> Enum.at(2) |> Map.fetch!("id")

      assert {:ok, [%{status: :accepted, actor_event: action_event}]} =
               Inbound.handle_card_action(
                 "interactive",
                 envelope(interactive_message("list_reply", token, "wamid.card-1")),
                 [consumer(agent.uid, "wa-list")]
               )

      assert action_event.type == "signal.action.invoked"

      assert {:ok, [%{status: :ignored_stale_action}]} =
               Inbound.handle_card_action(
                 "interactive",
                 envelope(interactive_message("list_reply", token, "wamid.text-1")),
                 [consumer(agent.uid, "wa-list")]
               )
    end

    test "a list stays inside the Cloud API row limit because the gateway caps the choices" do
      event_id = Ecto.UUID.generate()

      pending = pending_presentation(event_id, 14)

      assert %{"interactive" => %{"type" => "list"} = capped} =
               Presentation.action_message(pending, event_id, "pick")

      assert [%{"rows" => rows}] = capped["action"]["sections"]
      assert length(rows) == 8
      assert_valid_interactive!(Presentation.action_message(pending, event_id, "pick"))
    end

    test "short distinct labels keep their own words behind the ordinal" do
      event_id = Ecto.UUID.generate()
      presentation = presentation_with_labels(event_id, ["Yes", "No"])

      assert %{"interactive" => %{"type" => "button"} = interactive} =
               Presentation.action_message(presentation, event_id, "Ship it?")

      assert Enum.map(interactive["action"]["buttons"], &get_in(&1, ["reply", "title"])) ==
               ["1. Yes", "2. No"]

      # Nothing was cut, so the body stays the prompt alone.
      assert interactive["body"]["text"] == "Ship it?"
      assert_valid_interactive!(Presentation.action_message(presentation, event_id, "Ship it?"))
    end
  end

  describe "outbound messages" do
    test "splits long text, quotes only a reply, and renders a divider" do
      target = %{phone_number_id: @phone_number_id, wa_id: @wa_id}

      base = %OutboxEntry{
        agent_uid: "agent-a",
        binding_name: "wa-out",
        outbound_key: "out-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: "hello"
      }

      assert {:ok, [post]} = Outbox.messages(base, target, [])
      assert post["messaging_product"] == "whatsapp"
      assert post["recipient_type"] == "individual"
      assert post["to"] == @wa_id
      assert post["type"] == "text"
      assert post["text"]["body"] == "hello"
      refute Map.has_key?(post, "context")

      assert {:ok, [reply]} =
               Outbox.messages(
                 %{base | operation: :reply, reply_to_source_entry_id: "wamid.human-1"},
                 target,
                 []
               )

      assert reply["context"] == %{"message_id" => "wamid.human-1"}

      long = String.duplicate("あ", 4_097)

      assert {:ok, [first, second]} =
               Outbox.messages(%{base | fallback_visible_text: long}, target, [])

      assert String.length(first["text"]["body"]) == 4_096
      assert String.length(second["text"]["body"]) == 1

      assert {:ok, [divider]} =
               Outbox.messages(
                 %{base | operation: :divider, fallback_visible_text: ""},
                 target,
                 []
               )

      assert divider["text"]["body"] == "────────"

      assert {:error, :unsupported_outbox_operation} =
               Outbox.messages(%{base | operation: :edit}, target, [])
    end

    test "uploads an attachment and sends it as the typed media message" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-files")
      register_file_reader!(%{"report.pdf" => "report bytes"})

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request, conn.request_path, body})

        if String.ends_with?(conn.request_path, "/media") do
          Req.Test.json(conn, %{"id" => "uploaded-media-1"})
        else
          Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.file-1"}]})
        end
      end)

      outbox = attachment_outbox(agent.uid, "wa-files", "report.pdf", "application/pdf", 12)

      assert {:ok, %{created_source_entry_id: "wamid.file-1", payload: payload}} =
               Outbox.send(outbox)

      assert payload["whatsapp_message_ids"] == ["wamid.file-1"]
      assert_received {:request, upload_path, upload_body}
      assert upload_path =~ ~r{\A/v\d+\.\d+/#{@phone_number_id}/media\z}
      assert upload_body =~ "messaging_product"
      assert upload_body =~ "application/pdf"
      assert_received {:request, send_path, send_body}
      assert send_path =~ ~r{\A/v\d+\.\d+/#{@phone_number_id}/messages\z}

      assert %{"type" => "document", "document" => document} = Ankole.JSON.decode!(send_body)
      assert document["id"] == "uploaded-media-1"
      assert document["filename"] == "report.pdf"
    end

    test "a file the Cloud API cannot carry stops that attachment permanently" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-unsupported")

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "outbound_attachment_unsupported"}}} =
               Outbox.send(
                 attachment_outbox(
                   agent.uid,
                   "wa-unsupported",
                   "archive.zip",
                   "application/zip",
                   12
                 )
               )

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "outbound_attachment_unsupported"}}} =
               Outbox.send(
                 attachment_outbox(
                   agent.uid,
                   "wa-unsupported",
                   "huge.jpg",
                   "image/jpeg",
                   6 * 1024 * 1024
                 )
               )
    end

    test "classifies Graph failures and reports an uncertain send as unknown" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-errors")

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-errors",
        outbound_key: "errors-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: "hello"
      }

      stub_error = fn status, code ->
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(%{
            "error" => %{"message" => "Graph refused the request", "code" => code}
          })
        end)
      end

      stub_error.(401, 190)

      assert {:error, {:reply_delivery, :operator_action_required, detail}} = Outbox.send(outbox)
      assert detail["code"] == 190
      assert detail["status"] == 401
      refute detail["message"] =~ @access_token

      stub_error.(429, 130_429)
      assert {:error, {:reply_delivery, :retryable, _detail}} = Outbox.send(outbox)

      stub_error.(400, 131_056)
      assert {:error, {:reply_delivery, :retryable, _detail}} = Outbox.send(outbox)

      stub_error.(400, 131_000)
      assert {:error, {:reply_delivery, :retryable, _detail}} = Outbox.send(outbox)

      stub_error.(400, 131_016)
      assert {:error, {:reply_delivery, :retryable, _detail}} = Outbox.send(outbox)

      stub_error.(400, 131_048)
      assert {:error, {:reply_delivery, :operator_action_required, _detail}} = Outbox.send(outbox)

      stub_error.(400, 131_047)
      assert {:error, {:reply_delivery, :permanent, _detail}} = Outbox.send(outbox)

      stub_error.(400, 100)
      assert {:error, {:reply_delivery, :permanent, _detail}} = Outbox.send(outbox)

      # A send has no idempotency key and no read-back, so an uncertain answer
      # never becomes a plain retry.
      stub_error.(500, nil)
      assert :unknown = Outbox.send(outbox)

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert :unknown = Outbox.send(outbox)
    end

    test "a failure after one message of a split reply landed is unknown" do
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-partial")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.part-1"}]})

          _later ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => %{"message" => "rejected", "code" => 131_051}})
        end
      end)

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-partial",
        outbound_key: "partial-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: String.duplicate("a", 4_097)
      }

      assert :unknown = Outbox.send(outbox)
      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "customer service window" do
    test "a reply later than the window stops before any request, and a first contact sends" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-window")

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:sent, conn.request_path})
        Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.window-1"}]})
      end)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", envelope(text_message("hello")), [
                 consumer(agent.uid, "wa-window")
               ])

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-window",
        outbound_key: "window-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: "answer"
      }

      assert {:ok, %{created_source_entry_id: "wamid.window-1"}} = Outbox.send(outbox)
      assert_received {:sent, _path}

      entry = Repo.get_by!(Entry, signal_channel_id: @channel_id)

      Repo.update_all(
        from(row in Entry, where: row.document_id == ^entry.document_id),
        set: [provider_time: DateTime.add(DateTime.utc_now(:microsecond), -25 * 3600, :second)]
      )

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "customer_service_window_closed"}}} =
               Outbox.send(%{outbox | outbound_key: "window-2"})

      refute_received {:sent, _path}

      # A channel that holds no human message, such as the one that carries the
      # held-sender notice, never had a window to close.
      assert {:ok, %{created_source_entry_id: "wamid.window-1"}} =
               Outbox.send(%{
                 outbox
                 | outbound_key: "window-3",
                   signal_channel_id: "whatsapp:#{@phone_number_id}:14155550000"
               })

      assert_received {:sent, _path}
    end

    test "an accepted button reply re-opens the window that an aged message closed" do
      parent = self()
      %{agent: agent, event: event, presentation: presentation} = clarification("wa-reopen", 2)
      stub_typed_sends(parent)

      assert {:ok, %{created_source_entry_id: "wamid.text-1"}} =
               Outbox.send(card_row(agent, "wa-reopen", event, presentation))

      token = first_button_token(presentation, event.id)

      # The user's own newest message, older than the window. Only a message
      # with a platform subject is a human message to the pre-check.
      insert_aged_human_entry!(@channel_id, 25)

      follow_up = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-reopen",
        outbound_key: "reopen-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: "answer"
      }

      # The user's newest message is older than the window, so the Agent cannot
      # write first.
      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "customer_service_window_closed"}}} =
               Outbox.send(follow_up)

      bind_operator!()

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_card_action(
                 "interactive",
                 envelope(interactive_message("button_reply", token, "wamid.card-1")),
                 [consumer(agent.uid, "wa-reopen")]
               )

      # Meta counts that tap as a user action, and so does the pre-check: the
      # channel now carries the time WhatsApp reported for it.
      assert %Channel{metadata: %{"last_interactive_reply_at" => tapped_at}} =
               Repo.get(Channel, @channel_id)

      assert {:ok, _at, _offset} = DateTime.from_iso8601(tapped_at)

      assert {:ok, %{created_source_entry_id: "wamid.text-1"}} =
               Outbox.send(%{follow_up | outbound_key: "reopen-2"})
    end

    test "a redelivered tap keeps the time WhatsApp reported" do
      parent = self()
      %{agent: agent, event: event, presentation: presentation} = clarification("wa-late", 2)
      stub_typed_sends(parent)

      assert {:ok, %{created_source_entry_id: "wamid.text-1"}} =
               Outbox.send(card_row(agent, "wa-late", event, presentation))

      # Drain the card's own two messages, so the refutation below can only
      # catch a follow-up the pre-check should have stopped.
      assert_received {:sent, %{"type" => "text"}}
      assert_received {:sent, %{"type" => "interactive"}}

      token = first_button_token(presentation, event.id)
      insert_aged_human_entry!(@channel_id, 25)
      bind_operator!()

      # Meta redelivers a webhook it could not deliver for up to seven days, so
      # an accepted callback says nothing about when the user tapped.
      # WhatsApp reports whole seconds, and the stored fact keeps that precision.
      tapped_at =
        DateTime.utc_now(:microsecond)
        |> DateTime.add(-25 * 3600, :second)
        |> DateTime.truncate(:second)

      tap = interactive_message("button_reply", token, "wamid.card-1", tapped_at)
      consumer = consumer(agent.uid, "wa-late")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_card_action("interactive", envelope(tap), [consumer])

      follow_up = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-late",
        outbound_key: "late-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: "answer"
      }

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "customer_service_window_closed"}}} =
               Outbox.send(follow_up)

      refute_received {:sent, %{"type" => "text"}}

      # Meta also sends the same message twice. The repeat is not an error and
      # leaves the recorded tap time in place.
      assert {:ok, [%{status: :duplicate_action}]} =
               Inbound.handle_card_action("interactive", envelope(tap), [consumer])

      assert %Channel{metadata: %{"last_interactive_reply_at" => kept}} =
               Repo.get(Channel, @channel_id)

      assert {:ok, ^tapped_at, _offset} = DateTime.from_iso8601(kept)

      assert {:error,
              {:reply_delivery, :permanent, %{"code" => "customer_service_window_closed"}}} =
               Outbox.send(%{follow_up | outbound_key: "late-2"})
    end

    test "a redelivered older tap cannot move the window back" do
      parent = self()
      %{agent: agent, event: event, presentation: presentation} = clarification("wa-monotonic", 2)
      stub_typed_sends(parent)

      assert {:ok, %{created_source_entry_id: "wamid.text-1"}} =
               Outbox.send(card_row(agent, "wa-monotonic", event, presentation))

      assert_received {:sent, %{"type" => "text"}}
      assert_received {:sent, %{"type" => "interactive"}}

      token = first_button_token(presentation, event.id)
      insert_aged_human_entry!(@channel_id, 25)
      bind_operator!()
      consumer = consumer(agent.uid, "wa-monotonic")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_card_action(
                 "interactive",
                 envelope(interactive_message("button_reply", token, "wamid.card-1")),
                 [consumer]
               )

      assert %Channel{metadata: %{"last_interactive_reply_at" => fresh}} =
               Repo.get(Channel, @channel_id)

      # Meta delivers an older tap afterwards. The fact is monotonic, so the
      # window the fresh tap opened stays open.
      stale_tap =
        interactive_message(
          "button_reply",
          token,
          "wamid.card-1",
          DateTime.utc_now(:microsecond)
          |> DateTime.add(-25 * 3600, :second)
          |> DateTime.truncate(:second)
        )

      assert {:ok, [%{status: :duplicate_action}]} =
               Inbound.handle_card_action("interactive", envelope(stale_tap), [consumer])

      assert %Channel{metadata: %{"last_interactive_reply_at" => ^fresh}} =
               Repo.get(Channel, @channel_id)

      follow_up = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-monotonic",
        outbound_key: "monotonic-1",
        operation: :post,
        signal_channel_id: @channel_id,
        payload: %{},
        fallback_visible_text: "answer"
      }

      assert {:ok, %{created_source_entry_id: "wamid.text-1"}} = Outbox.send(follow_up)
      assert_received {:sent, %{"type" => "text"}}
    end

    test "a reply to a channel of another phone number waits for the operator" do
      parent = self()
      %{principal: agent} = agent_fixture()
      assert {:ok, _binding} = put_whatsapp_binding(agent.uid, "wa-moved")

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:sent, conn.request_path})
        Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.moved-1"}]})
      end)

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "wa-moved",
        outbound_key: "moved-1",
        operation: :post,
        signal_channel_id: Presentation.signal_channel_id(@other_phone_number_id, @wa_id),
        payload: %{},
        fallback_visible_text: "answer"
      }

      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{"code" => "binding_phone_number_mismatch"}}} = Outbox.send(outbox)

      refute_received {:sent, _path}
    end
  end

  defp first_button_token(presentation, actor_event_id) do
    presentation
    |> Presentation.action_message(actor_event_id, "Deploy to production?")
    |> get_in(["interactive", "action", "buttons"])
    |> List.first()
    |> get_in(["reply", "id"])
  end

  defp insert_aged_human_entry!(signal_channel_id, hours) do
    at = DateTime.add(DateTime.utc_now(:microsecond), -hours * 3600, :second)

    Repo.insert!(%Entry{
      document_id: "aged-human-#{System.unique_integer([:positive])}",
      signal_channel_id: signal_channel_id,
      source_entry_id: "wamid.aged-#{System.unique_integer([:positive])}",
      author: %{"platform_subject" => @wa_id, "provider" => "whatsapp"},
      text: "an older question",
      provider_time: at,
      first_seen_at: at,
      last_seen_at: at
    })
  end

  defp clarification(binding_name, action_count) do
    %{principal: agent} = agent_fixture()
    human_fixture(%{uid: "human-#{binding_name}"})
    assert {:ok, _binding} = put_whatsapp_binding(agent.uid, binding_name)
    now = DateTime.utc_now(:microsecond)

    %{actor_event: %ActorEvent{} = event} =
      emit_addressed_actor_event(
        agent.uid,
        binding_name,
        %{
          source_event_id: "wamid.question-#{binding_name}",
          signal_channel_id: @channel_id,
          source_entry_id: "wamid.question-#{binding_name}",
          channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
          text: "deploy?",
          explicit: true,
          author: %{principal_uid: "human-#{binding_name}", id: @wa_id},
          provider_time: now
        },
        now
      )

    presentation = pending_presentation(event.id, action_count)
    checkpoint = ReplyInteractionState.initialize(%{}, presentation, now)
    assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)

    %{agent: agent, event: event, presentation: presentation}
  end

  defp card_row(agent, binding_name, event, presentation) do
    Repo.insert!(%OutboxEntry{
      agent_uid: agent.uid,
      binding_name: binding_name,
      outbound_key: "ai-reply:clarify-#{binding_name}",
      operation: :reply,
      status: :created,
      delivery_class: :durable_ai_reply,
      signal_channel_id: @channel_id,
      reply_to_source_entry_id: "wamid.question-#{binding_name}",
      source_actor_event_id: event.id,
      payload: %{"reply_presentation" => presentation},
      fallback_visible_text: "Deploy to production?"
    })
  end

  # One id per message type, so a test can tell the text chunk and the
  # interactive message apart in the recorded surface.
  defp stub_typed_sends(parent) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Ankole.JSON.decode!(body)
      if decoded["type"] == "interactive", do: assert_valid_interactive!(decoded)
      send(parent, {:sent, decoded})

      id =
        case decoded["type"] do
          "interactive" -> "wamid.card-1"
          _text_or_media -> "wamid.text-1"
        end

      Req.Test.json(conn, %{"messages" => [%{"id" => id}]})
    end)
  end

  defp bind_operator! do
    %{principal: operator} = human_fixture()

    assert {:ok, _identity} =
             MappingRequests.bind_subject(operator.uid, %{
               provider: "whatsapp",
               external_id: @wa_id
             })

    operator
  end

  # Meta refuses a whole interactive message that breaks any of these limits, so
  # every payload the adapter builds is checked against all of them.
  defp assert_valid_interactive!(%{"type" => "interactive", "interactive" => interactive}) do
    assert String.length(interactive["body"]["text"]) <= 1_024

    case interactive["type"] do
      "button" ->
        buttons = interactive["action"]["buttons"]
        titles = Enum.map(buttons, &get_in(&1, ["reply", "title"]))
        ids = Enum.map(buttons, &get_in(&1, ["reply", "id"]))

        assert length(buttons) <= 3
        assert Enum.all?(titles, &(String.length(&1) <= 20))
        assert Enum.uniq(titles) == titles
        assert Enum.all?(ids, &(byte_size(&1) <= 256))
        assert Enum.uniq(ids) == ids

      "list" ->
        assert [%{"rows" => rows}] = interactive["action"]["sections"]
        titles = Enum.map(rows, & &1["title"])
        ids = Enum.map(rows, & &1["id"])

        assert length(rows) <= 10
        assert Enum.all?(titles, &(String.length(&1) <= 24))
        assert Enum.uniq(titles) == titles
        assert Enum.all?(ids, &(byte_size(&1) <= 256))
        assert Enum.uniq(ids) == ids
        assert String.length(interactive["action"]["button"]) <= 20

        assert Enum.all?(rows, fn row ->
                 is_nil(row["description"]) or String.length(row["description"]) <= 72
               end)
    end
  end

  defp presentation_with_labels(actor_event_id, labels) do
    actions =
      labels
      |> Enum.with_index(1)
      |> Enum.map(fn {label, index} ->
        %{
          "type" => "button",
          "id" => "option-#{index}",
          "label" => label,
          "interaction_id" => "interaction-1",
          "source_actor_event_id" => actor_event_id,
          "control_id" => "control-#{index}",
          "selected_option_id" => "option-#{index}",
          "option_value" => "value-#{index}",
          "revision" => 3
        }
      end)

    ReplyPresentation.new(state: "awaiting_input")
    |> Map.merge(%{
      "interaction_status" => "pending",
      "prompt" => "Ship it?",
      "actions" => actions
    })
  end

  defp pending_presentation(actor_event_id, count) do
    actions =
      for index <- 1..count do
        %{
          "type" => "button",
          "id" => "option-#{index}",
          "label" => "Approve the deployment option #{index}",
          "interaction_id" => "interaction-1",
          "source_actor_event_id" => actor_event_id,
          "control_id" => "control-#{index}",
          "selected_option_id" => "option-#{index}",
          "option_value" => "value-#{index}",
          "revision" => 3
        }
      end

    ReplyPresentation.new(state: "awaiting_input")
    |> Map.merge(%{
      "interaction_status" => "pending",
      "prompt" => "Deploy to production?",
      "actions" => actions
    })
  end

  defp attachment_outbox(agent_uid, binding_name, name, mime_type, size) do
    %OutboxEntry{
      agent_uid: agent_uid,
      binding_name: binding_name,
      outbound_key: "attachment-#{name}",
      operation: :post,
      signal_channel_id: @channel_id,
      payload: %{
        "attachments" => [
          %{
            "agent_computer_path" => "/agents/#{agent_uid}/user-files/outbox/#{name}",
            "user_files_relative_path" => "outbox/#{name}",
            "name" => name,
            "size" => size,
            "mime_type" => mime_type
          }
        ]
      },
      fallback_visible_text: nil
    }
  end

  defp complete?(channel_id, source_entry_id),
    do: attachment_state?(channel_id, source_entry_id, "complete")

  defp restricted?(channel_id, source_entry_id),
    do: attachment_state?(channel_id, source_entry_id, "provider_download_limit")

  defp attachment_state?(channel_id, source_entry_id, state) do
    case Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: source_entry_id) do
      %Entry{attachments: [%{"materialization_state" => ^state}]} -> true
      _other -> false
    end
  end

  defp binding_config do
    %{
      "appId" => @app_id,
      "appSecret" => @app_secret,
      "verifyToken" => @verify_token,
      "phoneNumberId" => @phone_number_id,
      "accessToken" => @access_token
    }
  end

  defp put_whatsapp_binding(agent_uid, name, attrs \\ %{}) do
    SignalsGateway.put_binding(
      agent_uid,
      "whatsapp",
      name,
      Map.merge(
        %{
          "config" => binding_config(),
          "group_message_mode" => "addressed_only",
          "unmatched_sender_policy" => "create_standalone"
        },
        attrs
      )
    )
  end

  defp consumer(agent_uid, binding_name, config \\ nil) do
    Inbound.chat_consumer(
      AdapterContext.new(
        agent_uid: agent_uid,
        binding_name: binding_name,
        adapter: "whatsapp",
        user_name: "WhatsApp"
      ),
      config || binding_config()
    )
  end

  defp value(messages) do
    %{
      "messaging_product" => "whatsapp",
      "metadata" => %{
        "display_phone_number" => "15550001111",
        "phone_number_id" => @phone_number_id
      },
      "contacts" => [%{"profile" => %{"name" => "Ada"}, "wa_id" => @wa_id}],
      "messages" => messages
    }
  end

  defp envelope(message), do: %{"value" => value([message]), "message" => message}

  defp signed_request(value) do
    payload = %{
      "object" => "whatsapp_business_account",
      "entry" => [%{"id" => "WABA-1", "changes" => [%{"field" => "messages", "value" => value}]}]
    }

    body = Ankole.JSON.encode!(payload)

    %{
      handler_id: "whatsapp",
      instance_id: @app_id,
      kind: "events",
      method: "POST",
      query_params: %{},
      body_params: payload,
      raw_body: body,
      headers: %{"x-hub-signature-256" => Signature.sign(body, @app_secret)}
    }
  end

  defp verification_request(token, mode) do
    %{
      handler_id: "whatsapp",
      instance_id: @app_id,
      kind: "events",
      method: "GET",
      query_params: %{
        "hub.mode" => mode,
        "hub.verify_token" => token,
        "hub.challenge" => "challenge-1"
      },
      body_params: %{},
      raw_body: "",
      headers: %{}
    }
  end

  defp message(attrs) do
    Map.merge(
      %{
        "id" => "wamid.#{System.unique_integer([:positive])}",
        "from" => @wa_id,
        "timestamp" => Integer.to_string(DateTime.to_unix(DateTime.utc_now()))
      },
      attrs
    )
  end

  defp text_message(text), do: message(%{"type" => "text", "text" => %{"body" => text}})

  defp media_message(type, media), do: message(%{"type" => type, type => media})

  # `message/1` already stamps a current unix timestamp; `tapped_at` overrides it
  # so a test can act out a tap WhatsApp reported hours ago.
  defp interactive_message(reply_type, token, context_id, tapped_at \\ nil) do
    built =
      message(%{
        "type" => "interactive",
        "context" => %{"from" => @phone_number_id, "id" => context_id},
        "interactive" => %{"type" => reply_type, reply_type => %{"id" => token, "title" => "Yes"}}
      })

    case tapped_at do
      nil -> built
      %DateTime{} = at -> Map.put(built, "timestamp", Integer.to_string(DateTime.to_unix(at)))
    end
  end

  # A fake worker that accepts the user-files write of a downloaded attachment.
  defp register_file_writer!(binding_name) do
    parent = self()
    route = "#{binding_name}-write-#{System.unique_integer([:positive])}"
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
  end

  # The outbox reads attachment bytes out of the Agent's user-files lane, so a
  # ready worker has to answer the read frames for that lane.
  defp register_file_reader!(contents) do
    route = "whatsapp-read-#{System.unique_integer([:positive])}"
    worker = insert_ready_worker!(route)
    route_auth = %{route: route, worker_id: worker.worker_id}
    {:ok, transfers} = Agent.start_link(fn -> %{} end)

    :ok =
      Broker.register_local_worker(route, fn
        {:file_transfer_lane, [protocol, "READ_OPEN", transfer_id, path, _fingerprint]} ->
          content = Map.fetch!(contents, Path.basename(path))
          Agent.update(transfers, &Map.put(&1, transfer_id, content))

          FileTransferLane.handle_worker_frame(route_auth, [
            protocol,
            "READ_READY",
            transfer_id,
            path,
            u64(byte_size(content)),
            ""
          ])

        {:file_transfer_lane, [protocol, "CREDIT", transfer_id, _credit]} ->
          content = Agent.get(transfers, &Map.fetch!(&1, transfer_id))
          wire = Ankole.Kernel.zstd_compress_block(content, 3)

          FileTransferLane.handle_worker_frame(route_auth, [
            protocol,
            "DATA",
            transfer_id,
            u64(0),
            u64(0),
            <<1>>,
            wire
          ])

          FileTransferLane.handle_worker_frame(route_auth, [
            protocol,
            "READ_DONE",
            transfer_id,
            u64(1),
            u64(byte_size(wire))
          ])
      end)

    on_exit(fn -> Broker.unregister_local_worker(route) end)
  end

  defp insert_ready_worker!(route) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: "whatsapp-worker-#{System.unique_integer([:positive])}",
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
