defmodule Ankole.Conversations.AdapterSignalRoundtripTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.AIGatewayCase,
    only: [start_upstream_server: 1, chat_completion_stream_events: 2]

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.SessionsCase, only: [agent_fixture: 1, cache_actor_runtime_models: 1]

  alias Ankole.AppConfigure
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Conversations.{AdapterContext, Conversation, Message}
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Signals.Signal
  alias Ankole.SessionsCase, as: RuntimeCase

  @adapters [
    {"lark", Ankole.Plugins.LarkAdapter},
    {"slack", Ankole.Plugins.SlackAdapter},
    {"dingtalk", Ankole.Plugins.DingTalkAdapter},
    {"wecom", Ankole.Plugins.WeComAdapter},
    {"teams", Ankole.Plugins.Microsoft365Adapter},
    {"telegram", Ankole.Plugins.TelegramAdapter},
    {"discord", Ankole.Plugins.DiscordAdapter},
    {"whatsapp", Ankole.Plugins.WhatsAppAdapter},
    {"line", Ankole.Plugins.LineAdapter},
    {"email", Ankole.Plugins.EmailAdapter}
  ]

  setup %{tenant: tenant, adapter: adapter, plugin: plugin} do
    drivers = RuntimeCase.driver_pids()
    previews = RuntimeCase.preview_handler_pids()
    owner = self()
    requests = :counters.new(1, [])
    nonce = Ecto.UUID.generate()
    answer = "ROUTE_#{adapter}_#{nonce}"

    %{principal: agent} = agent_fixture(%{})
    %{principal: other} = Ankole.PrincipalsFixtures.agent_fixture()
    {:ok, profile} = ModelProfiles.get_model_profile(agent.uid, "primary")

    url =
      start_upstream_server(fn request ->
        assert request.request_path == "/chat/completions"
        :counters.add(requests, 1, 1)
        send(owner, {:model_request, request})
        {:sse, 200, chat_completion_stream_events(request, answer)}
      end)

    {:ok, _} = ProviderConfigs.update_provider(profile["provider_id"], %{base_url: url})
    :ok = cache_actor_runtime_models(profile["provider_id"])
    config_module = Module.concat(plugin, Config)
    inbound = Module.concat(plugin, Inbound)
    config = adapter_config(adapter, nonce)

    previous_req = Req.default_options()
    previous_config = Application.get_env(:ankole, config_module)
    Req.default_options(plug: &platform_request(&1, adapter, owner))
    Application.put_env(:ankole, config_module, [])

    on_exit(fn ->
      Req.default_options(previous_req)

      if previous_config,
        do: Application.put_env(:ankole, config_module, previous_config),
        else: Application.delete_env(:ankole, config_module)
    end)

    on_exit(
      Repo.bind_tenant(fn ->
        RuntimeCase.stop_new_drivers(drivers)
        RuntimeCase.stop_new_preview_handlers(previews)

        Repo.delete_all(Conversation)

        Repo.delete_all(
          from job in Oban.Job, where: job.args["agent_uid"] in ^[agent.uid, other.uid]
        )

        for uid <- [agent.uid, other.uid] do
          {:ok, bindings} = Ankole.Signals.Bindings.list_bindings(uid)

          for %{config_ref: "app-config://" <> key} <- bindings do
            :ok = AppConfigure.delete_global_by_key(key)
          end

          :ok = Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(Repo, uid)
          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(uid)
        end

        if adapter in ["lark", "slack"] do
          reconciler = Module.concat(plugin, ConnectionReconciler)
          assert %{started: 0, errors: []} = reconciler.reconcile()
          assert reconciler.registered_keys() == []
        end

        {:ok, _} = ProviderConfigs.delete_provider(profile["provider_id"])
        Repo.delete_all(Ankole.Brain.Schemas.Object)
        Repo.delete_all(Ankole.AuthZ.Group)
        Repo.delete_all(Ankole.Principals.Principal)
        Repo.delete!(tenant)
      end)
    )

    transport = start_transport(adapter, config, config_module)

    assert {:ok, %{binding: binding}} =
             Ankole.Signals.Bindings.put_binding(agent.uid, adapter, "roundtrip", %{
               "config" => config,
               "group_message_mode" => "addressed_only",
               "unmatched_sender_policy" => "create_standalone"
             })

    assert {:ok, config} = Ankole.Signals.Bindings.stored_binding_config(binding)

    runtime_config =
      case adapter do
        "lark" -> Map.put(config, "runtimeBotOpenID", "ou_bot")
        "slack" -> Map.put(config, "runtimeBotUserID", "UBOT")
        _ -> config
      end

    consumer =
      inbound.chat_consumer(
        AdapterContext.new(
          agent_uid: agent.uid,
          binding_name: binding.name,
          adapter: adapter,
          user_name: "Route test"
        ),
        runtime_config
      )

    {:ok,
     agent: agent,
     other: other,
     inbound: inbound,
     consumer: consumer,
     nonce: nonce,
     answer: answer,
     requests: requests,
     transport: transport}
  end

  for {adapter, plugin} <- @adapters,
      chat_kind <- if(adapter == "whatsapp", do: [:direct], else: [:direct, :shared]) do
    @tag adapter: adapter, plugin: plugin, chat_kind: chat_kind
    test "#{adapter} #{chat_kind} input reaches the model and its source once, then continues the same Session",
         ctx do
      first = context_event(ctx, 1, "First route request #{ctx.nonce}")
      assert {:ok, _} = ctx.inbound.handle_message_receive("message", first, [ctx.consumer])
      request = await_model_request()
      assert Ankole.JSON.encode!(request.body["messages"]) =~ ctx.nonce
      signal = await_completed_signal(ctx.agent.uid, 1)
      assert signal.type == "conversation.message.addressed"
      assert signal.attempt_count == 1
      assert signal.human_uid
      assert signal.conversation_id
      assert signal.session_id == Ankole.Sessions.Key.conversation(signal.conversation_id)
      intent = deliver_reply(signal, ctx.answer)
      assert_source_output(ctx, intent)

      assert {:ok, _} = ctx.inbound.handle_message_receive("message", first, [ctx.consumer])
      drain_inbound()
      refute_receive {:model_request, _}, 150
      assert :counters.get(ctx.requests, 1) == 1
      assert Repo.aggregate(from(s in Signal, where: s.agent_uid == ^ctx.agent.uid), :count) == 1
      assert Repo.get_by!(Intent, Ecto.primary_key(intent)).status == :sent

      second = context_event(ctx, 2, "Follow-up route request #{ctx.nonce}")
      assert {:ok, _} = ctx.inbound.handle_message_receive("message", second, [ctx.consumer])
      followup = await_model_request()
      encoded = Ankole.JSON.encode!(followup.body["messages"])
      assert encoded =~ "Follow-up route request #{ctx.nonce}"
      assert encoded =~ ctx.answer
      continued = await_completed_signal(ctx.agent.uid, 2)
      assert continued.session_id == signal.session_id
      assert continued.conversation_id == signal.conversation_id
      assert continued.attempt_count == 1
      deliver_reply(continued, ctx.answer)
      assert :counters.get(ctx.requests, 1) == 2
      refute Repo.exists?(from s in Signal, where: s.agent_uid == ^ctx.other.uid)

      assert Repo.aggregate(
               from(i in Intent,
                 where: i.agent_uid == ^ctx.agent.uid and i.delivery_class == :durable_ai_reply
               ),
               :count
             ) == 2

      assert Repo.aggregate(
               from(m in Message,
                 where: m.conversation_id == ^signal.conversation_id and m.author_type == :human
               ),
               :count
             ) == 2
    end
  end

  defp drain_inbound do
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
  end

  defp await_model_request(attempts \\ 400)
  defp await_model_request(0), do: flunk("No model request after platform input")

  defp await_model_request(attempts) do
    drain_inbound()

    receive do
      {:model_request, request} -> request
    after
      25 -> await_model_request(attempts - 1)
    end
  end

  defp await_completed_signal(uid, count) do
    assert {:ok, signal} =
             wait_until(deadline(10_000), fn ->
               signals =
                 Repo.all(from s in Signal, where: s.agent_uid == ^uid, order_by: s.inserted_at)

               if length(signals) == count and Enum.all?(signals, & &1.completed_at),
                 do: List.last(signals)
             end)

    assert is_nil(signal.dead_letter_reason)
    signal
  end

  defp deliver_reply(signal, answer) do
    intent =
      Repo.one!(
        from i in Intent,
          where: i.source_signal_id == ^signal.id and i.delivery_class == :durable_ai_reply
      )

    assert intent.conversation_id == signal.conversation_id
    assert intent.fallback_visible_text =~ answer

    unless intent.status == :sent do
      assert {:ok, _} =
               Delivery.dispatch_by_key(
                 intent.agent_uid,
                 intent.binding_name,
                 intent.outbound_key
               )
    end

    stored = Repo.get_by!(Intent, Ecto.primary_key(intent))

    assert %{status: :sent} = stored
    stored
  end

  defp assert_source_output(%{adapter: "email", answer: answer} = ctx, _intent) do
    assert_receive {:smtp_data, "agent@route.example", recipients, raw}, 5_000

    expected =
      if ctx.chat_kind == :shared,
        do: ["sender@example.com", "colleague@example.com"],
        else: ["sender@example.com"]

    assert MapSet.new(recipients) == MapSet.new(expected)
    assert raw =~ "In-Reply-To: <route-"
    assert raw =~ answer
  end

  defp assert_source_output(%{adapter: "wecom", transport: fake, answer: answer}, _intent) do
    frames = Ankole.E2E.FakeWeCom.State.frames(fake.state, "aibot_respond_msg")
    assert Enum.any?(frames, &(Ankole.JSON.encode!(&1) =~ answer))
    assert Enum.all?(frames, &(get_in(&1, ["headers", "req_id"]) == "route-req-1"))
  end

  defp assert_source_output(ctx, _intent) do
    assert {:ok, {path, body}} =
             wait_until(deadline(5_000), fn ->
               receive do
                 {:platform_output, adapter, path, body} ->
                   assert adapter == ctx.adapter
                   if Ankole.JSON.encode!(body) =~ ctx.answer, do: {path, body}
               after
                 0 -> nil
               end
             end)

    assert_source_target(ctx, path, body)
  end

  defp start_transport("wecom", config, config_module) do
    fake = Ankole.E2E.FakeWeCom.Server.start!()
    key = config_module.connection_key(config)

    socket =
      start_supervised!(
        {WeComOpenAPI.Bot.Client,
         name: Ankole.Plugins.WeComAdapter.ConnectionOwner.client_name(key),
         bot_id: config["botId"],
         secret: config["secret"],
         ws_url: fake.ws_url,
         dispatcher: WeComOpenAPI.Bot.Dispatcher.new()}
      )

    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               WeComOpenAPI.Bot.Client.status(socket) == :connected
             end)

    fake
  end

  defp start_transport("email", _config, config_module) do
    {port, cacerts} = Ankole.EmailTransportFixtures.start_fake_tls_smtp()

    Application.put_env(:ankole, config_module,
      smtp_opts: [
        relay: ~c"localhost",
        port: port,
        ssl: true,
        tls: :never,
        sockopts: config_module.tls_options(~c"localhost") ++ [cacerts: cacerts],
        timeout: 5_000
      ]
    )
  end

  defp start_transport(_adapter, _config, _module), do: nil

  defp assert_source_target(%{adapter: "lark", nonce: nonce}, path, body),
    do: assert(String.contains?(path, "om_#{nonce}_1") or body["receive_id"] == "oc_#{nonce}")

  defp assert_source_target(%{adapter: "slack", nonce: nonce, chat_kind: kind}, _path, body),
    do: assert(body["channel"] == "#{if kind == :shared, do: "C", else: "D"}#{nonce}")

  defp assert_source_target(
         %{adapter: "dingtalk", chat_kind: :shared, nonce: nonce},
         _path,
         body
       ),
       do: assert(body["openConversationId"] == "cid#{nonce}")

  defp assert_source_target(%{adapter: "dingtalk"}, _path, body),
    do: assert(body["userIds"] == ["sender"])

  defp assert_source_target(%{adapter: "teams", nonce: nonce}, path, _body),
    do: assert(path =~ URI.encode("19:#{nonce}", &URI.char_unreserved?/1))

  defp assert_source_target(%{adapter: "telegram", chat_kind: kind}, _path, body),
    do: assert(to_string(body["chat_id"]) == if(kind == :shared, do: "-100501", else: "501"))

  defp assert_source_target(%{adapter: "discord"}, path, _body),
    do: assert(path =~ "/channels/501/messages")

  defp assert_source_target(%{adapter: "whatsapp"}, _path, body),
    do: assert(body["to"] == "14155552671")

  defp assert_source_target(%{adapter: "line", chat_kind: kind}, _path, body),
    do: assert(body["to"] == if(kind == :shared, do: "Croute", else: "Usender"))

  defp context_event(ctx, n, text) do
    event = raw_event(ctx.adapter, ctx.nonce, n, text)
    if ctx.chat_kind == :shared, do: shared_event(ctx.adapter, event), else: event
  end

  defp shared_event("lark", event) do
    message = event.content["message"]
    text = Ankole.JSON.decode!(message["content"])["text"]

    message =
      Map.merge(message, %{
        "chat_type" => "group",
        "content" => Ankole.JSON.encode!(%{"text" => "@_user_1 " <> text}),
        "mentions" => [%{"key" => "@_user_1", "name" => "Bot", "id" => %{"open_id" => "ou_bot"}}]
      })

    %{event | content: Map.put(event.content, "message", message)}
  end

  defp shared_event("slack", event) do
    content = event.content

    %{
      event
      | content:
          Map.merge(content, %{
            "channel" => String.replace_prefix(content["channel"], "D", "C"),
            "channel_type" => "channel",
            "text" => "<@UBOT> " <> content["text"]
          })
    }
  end

  defp shared_event("dingtalk", event),
    do: %{event | data: Map.merge(event.data, %{"conversationType" => "2", "isInAtList" => true})}

  defp shared_event("wecom", event),
    do: %{
      event
      | body: Map.merge(event.body, %{"chattype" => "group", "chatid" => "group-route"})
    }

  defp shared_event("teams", event) do
    event
    |> put_in(["conversation", "conversationType"], "channel")
    |> Map.put("entities", [
      %{"type" => "mention", "text" => "<at>Ankole</at>", "mentioned" => event["recipient"]}
    ])
    |> Map.put("text", "<at>Ankole</at> " <> event["text"])
  end

  defp shared_event("telegram", event) do
    event
    |> put_in(["message", "chat"], %{
      "id" => -100_501,
      "type" => "supergroup",
      "title" => "Route group"
    })
    |> put_in(["message", "text"], "@AnkoleBot " <> event["message"]["text"])
    |> put_in(["message", "entities"], [%{"type" => "mention", "offset" => 0, "length" => 10}])
  end

  defp shared_event("discord", event) do
    event
    |> put_in(["message", "guild_id"], "600")
    |> put_in(["message", "mentions"], [%{"id" => "77", "bot" => true}])
    |> put_in(["message", "content"], "<@77> " <> event["message"]["content"])
  end

  defp shared_event("line", event) do
    event
    |> put_in(["event", "source"], %{
      "type" => "group",
      "groupId" => "Croute",
      "userId" => "Usender"
    })
    |> put_in(["event", "message", "text"], "@Bot " <> event["event"]["message"]["text"])
    |> put_in(["event", "message", "mention"], %{
      "mentionees" => [%{"index" => 0, "length" => 4, "isSelf" => true}]
    })
  end

  defp shared_event("email", event) do
    raw =
      String.replace(event["raw"], "Subject:", "Cc: colleague@example.com\r\nSubject:",
        global: false
      )

    Map.merge(event, %{"raw" => raw, "size" => byte_size(raw)})
  end

  defp adapter_config("lark", nonce), do: %{"appID" => "cli_#{nonce}", "appSecret" => "test"}

  defp adapter_config("slack", _),
    do: %{"botToken" => "xoxb-test", "appToken" => "xapp-test", "botUserID" => "UBOT"}

  defp adapter_config("dingtalk", nonce),
    do: %{"clientId" => "client-#{nonce}", "clientSecret" => "test"}

  defp adapter_config("wecom", nonce), do: %{"botId" => "bot-#{nonce}", "secret" => "test"}

  defp adapter_config("teams", _),
    do: %{
      "appID" => "11111111-2222-3333-4444-555555555555",
      "appPassword" => "test",
      "tenantID" => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    }

  defp adapter_config(adapter, _) when adapter in ["telegram", "discord"],
    do: %{"botToken" => "test-only-token"}

  defp adapter_config("whatsapp", _),
    do: %{
      "appId" => "1009900000001",
      "appSecret" => "test",
      "verifyToken" => "test",
      "phoneNumberId" => "1500000000001",
      "accessToken" => "test"
    }

  defp adapter_config("line", _),
    do: %{"channelId" => "1650000001", "channelSecret" => "test", "channelAccessToken" => "test"}

  defp adapter_config("email", _),
    do: %{
      "address" => "agent@route.example",
      "imapHost" => "imap.route.example",
      "smtpHost" => "smtp.route.example",
      "username" => "agent",
      "password" => "secret"
    }

  defp raw_event("telegram", _nonce, n, text) do
    %{
      "update_id" => n,
      "bot" => %{id: 77, username: "AnkoleBot"},
      "message" => %{
        "message_id" => n,
        "date" => System.system_time(:second),
        "chat" => %{"id" => 501, "type" => "private"},
        "from" => %{"id" => 100, "is_bot" => false, "first_name" => "Sender"},
        "text" => text
      }
    }
  end

  defp raw_event("discord", _nonce, n, text) do
    %{
      "bot" => %{id: "77", username: "AnkoleBot"},
      "message" => %{
        "id" => to_string(n),
        "channel_id" => "501",
        "type" => 0,
        "content" => text,
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "author" => %{"id" => "100", "username" => "sender", "global_name" => "Sender"}
      }
    }
  end

  defp raw_event("whatsapp", nonce, n, text) do
    message = %{
      "id" => "wamid.#{nonce}.#{n}",
      "from" => "14155552671",
      "timestamp" => to_string(System.system_time(:second)),
      "type" => "text",
      "text" => %{"body" => text}
    }

    %{
      "message" => message,
      "value" => %{
        "messaging_product" => "whatsapp",
        "metadata" => %{"phone_number_id" => "1500000000001"},
        "messages" => [message],
        "contacts" => [%{"wa_id" => "14155552671", "profile" => %{"name" => "Sender"}}]
      }
    }
  end

  defp raw_event("line", nonce, n, text) do
    %{
      "destination" => "Ubot",
      "event" => %{
        "type" => "message",
        "mode" => "active",
        "timestamp" => System.system_time(:millisecond),
        "webhookEventId" => "#{nonce}-#{n}",
        "source" => %{"type" => "user", "userId" => "Usender"},
        "message" => %{"id" => to_string(n), "type" => "text", "text" => text}
      }
    }
  end

  defp raw_event("teams", nonce, n, text) do
    %{
      "type" => "message",
      "id" => "#{nonce}-#{n}",
      "text" => text,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "channelId" => "msteams",
      "serviceUrl" => "https://smba.trafficmanager.net/teams/",
      "from" => %{"id" => "29:sender", "aadObjectId" => "sender", "name" => "Sender"},
      "recipient" => %{"id" => "28:11111111-2222-3333-4444-555555555555"},
      "conversation" => %{"id" => "19:#{nonce}", "conversationType" => "personal"},
      "channelData" => %{"tenant" => %{"id" => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}}
    }
  end

  defp raw_event("email", nonce, n, text) do
    headers = [
      "Authentication-Results: mx.route.example; dmarc=pass header.from=example.com",
      "Message-ID: <route-#{nonce}-#{n}@example.com>",
      "From: Sender <sender@example.com>",
      "To: Agent <agent@route.example>",
      "Subject: Route test #{nonce}",
      "Date: " <> Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000"),
      "Content-Type: text/plain; charset=utf-8"
    ]

    headers =
      if n == 2, do: headers ++ ["In-Reply-To: <route-#{nonce}-1@example.com>"], else: headers

    raw = Enum.join(headers, "\r\n") <> "\r\n\r\n" <> text

    %{
      "uid" => n,
      "uidvalidity" => 7,
      "raw" => raw,
      "size" => byte_size(raw),
      "headers_only" => false
    }
  end

  defp raw_event("lark", nonce, n, text) do
    %FeishuOpenAPI.Event{
      id: "#{nonce}-#{n}",
      type: "im.message.receive_v1",
      app_id: "cli_#{nonce}",
      created_at: DateTime.utc_now(),
      raw: %{},
      content: %{
        "sender" => %{"sender_type" => "user", "sender_id" => %{"open_id" => "ou_sender"}},
        "message" => %{
          "message_id" => "om_#{nonce}_#{n}",
          "chat_id" => "oc_#{nonce}",
          "chat_type" => "p2p",
          "message_type" => "text",
          "content" => Ankole.JSON.encode!(%{"text" => text}),
          "create_time" => to_string(System.system_time(:millisecond))
        }
      }
    }
  end

  defp raw_event("slack", nonce, n, text) do
    %SlackOpenAPI.Event{
      id: "#{nonce}-#{n}",
      type: "message",
      team_id: "T1",
      api_app_id: "A1",
      created_at: DateTime.utc_now(),
      raw: %{},
      content: %{
        "channel" => "D#{nonce}",
        "channel_type" => "im",
        "user" => "USENDER",
        "ts" => "#{System.system_time(:second)}.00000#{n}",
        "text" => text
      }
    }
  end

  defp raw_event("dingtalk", nonce, n, text) do
    %DingTalkOpenAPI.Event{
      data: %{
        "msgId" => "#{nonce}-#{n}",
        "conversationId" => "cid#{nonce}",
        "conversationType" => "1",
        "senderStaffId" => "sender",
        "senderNick" => "Sender",
        "msgtype" => "text",
        "text" => %{"content" => text},
        "createAt" => System.system_time(:millisecond)
      }
    }
  end

  defp raw_event("wecom", nonce, n, text) do
    %WeComOpenAPI.Bot.Event{
      req_id: "route-req-#{n}",
      body: %{
        "msgid" => "#{nonce}-#{n}",
        "chattype" => "single",
        "from" => %{"userid" => "sender"},
        "msgtype" => "text",
        "text" => %{"content" => text}
      }
    }
  end

  defp platform_request(conn, adapter, owner) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)

    body =
      case Ankole.JSON.decode(raw) do
        {:ok, data} -> data
        _ -> URI.decode_query(raw)
      end

    path = conn.request_path
    id = "sent-#{System.unique_integer([:positive])}"

    response =
      cond do
        adapter == "slack" and String.ends_with?(path, "/auth.test") ->
          %{"ok" => true, "user_id" => "UBOT", "bot_id" => "BBOT"}

        adapter == "slack" and String.ends_with?(path, "/bots.info") ->
          %{"ok" => true, "bot" => %{"app_id" => "AROUTE"}}

        adapter == "discord" and String.ends_with?(path, "/applications/@me") ->
          %{"id" => "app-route"}

        adapter == "telegram" and String.ends_with?(path, "/getMe") ->
          %{"ok" => true, "result" => %{"id" => 77, "is_bot" => true, "username" => "AnkoleBot"}}

        String.ends_with?(path, "/oauth2/v2.0/token") ->
          %{"access_token" => "test-token", "expires_in" => 3600}

        String.ends_with?(path, "/tenant_access_token/internal") ->
          %{"code" => 0, "tenant_access_token" => "test-token", "expire" => 7200}

        path == "/v1.0/oauth2/accessToken" ->
          %{"accessToken" => "test-token", "expireIn" => 7200}

        String.contains?(path, "users.info") ->
          %{"ok" => true, "user" => %{"id" => "USENDER", "name" => "Sender"}}

        String.contains?(path, "/profile/") ->
          %{"userId" => "Usender", "displayName" => "Sender"}

        adapter == "lark" and String.contains?(path, "/cardkit/") ->
          %{"code" => 200_860, "msg" => "CardKit unavailable in this fixture"}

        adapter == "lark" and String.contains?(path, "/messages") ->
          send(owner, {:platform_output, adapter, path, body})
          %{"code" => 0, "data" => %{"message_id" => id}}

        adapter == "slack" and String.contains?(path, "chat.") ->
          send(owner, {:platform_output, adapter, path, body})
          %{"ok" => true, "ts" => id, "channel" => body["channel"]}

        adapter == "dingtalk" and
            (String.ends_with?(path, "/batchSend") or
               String.ends_with?(path, "/groupMessages/send")) ->
          send(owner, {:platform_output, adapter, path, body})
          %{"processQueryKey" => id}

        adapter == "teams" and String.contains?(path, "/activities") ->
          send(owner, {:platform_output, adapter, path, body})
          %{"id" => id}

        adapter == "telegram" and
            (String.ends_with?(path, "/sendMessage") or
               String.ends_with?(path, "/editMessageText")) ->
          send(owner, {:platform_output, adapter, path, body})

          %{
            "ok" => true,
            "result" => %{
              "message_id" => System.unique_integer([:positive]),
              "date" => System.system_time(:second),
              "chat" => %{"id" => 501}
            }
          }

        adapter == "discord" and String.contains?(path, "/messages") ->
          send(owner, {:platform_output, adapter, path, body})

          %{
            "id" => id,
            "channel_id" => "501",
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }

        adapter == "whatsapp" and String.ends_with?(path, "/messages") ->
          send(owner, {:platform_output, adapter, path, body})
          %{"messages" => [%{"id" => id}]}

        adapter == "line" and String.ends_with?(path, "/message/push") ->
          send(owner, {:platform_output, adapter, path, body})
          %{"sentMessages" => [%{"id" => id}]}

        true ->
          %{"code" => 404, "error" => "No test endpoint for #{path}"}
      end

    Req.Test.json(conn, response)
  end
end
