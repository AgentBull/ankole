defmodule Ankole.Conversations.SharedAssistantBotTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures, only: [provider_author_fixture: 3]
  alias Ankole.Conversations.{AdapterContext, Delivery, InboundBatches}
  alias Ankole.Principals
  alias Ankole.Signals.Bindings

  setup do
    Req.Test.set_req_test_to_shared()
    worker_provider_fixture(%{is_default: true})
    previous = Req.default_options()
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "shared-token",
            "expire" => 7_200
          })

        "/open-apis/bot/v3/info" ->
          Req.Test.json(conn, %{"code" => 0, "bot" => %{"open_id" => "ou_bot"}})

        "/callback/ws/endpoint" ->
          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"code" => 1, "msg" => "offline test transport"})

        "/api/apps.connections.open" ->
          Req.Test.json(conn, %{"ok" => false, "error" => "service_unavailable"})

        "/api/auth.test" ->
          Req.Test.json(conn, %{
            "ok" => true,
            "user_id" => "UBOT",
            "bot_id" => "B1",
            "team_id" => "T1"
          })

        "/api/bots.info" ->
          Req.Test.json(conn, %{"ok" => true, "bot" => %{"id" => "B1", "app_id" => "A1"}})

        "/api/users.info" ->
          Req.Test.json(conn, %{"ok" => true, "user" => %{"id" => "U5", "name" => "Unknown"}})

        "/open-apis/contact/v3/users/U5" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"user" => %{"open_id" => "U5", "name" => "Unknown"}}
          })

        "/api/chat.postMessage" ->
          send(parent, {:sent, :slack, body})
          Req.Test.json(conn, %{"ok" => true, "channel" => "D1", "ts" => "1793440000.000099"})

        "/open-apis/im/v1/messages" ->
          send(parent, {:sent, :lark, body})
          Req.Test.json(conn, %{"code" => 0, "data" => %{"message_id" => "om_reply"}})

        path ->
          flunk("Unexpected provider request: #{path}")
      end
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {adapter, reconciler} <- [
            {"lark", Ankole.Plugins.LarkAdapter.ConnectionReconciler},
            {"slack", Ankole.Plugins.SlackAdapter.ConnectionReconciler}
          ] do
        # Drain save callbacks before removing the connection and its retry spec.
        :sys.get_state(reconciler)
        {:ok, validated} = config_module(adapter).validate_chat_config(config(adapter))
        :ok = reconciler.stop(config_module(adapter).connection_key(validated))
      end

      Req.default_options(previous)
    end)
  end

  for adapter <- ["lark", "slack"] do
    test "#{adapter}: one shared Bot routes each member to their full assistant and delivers by binding identity" do
      adapter = unquote(adapter)
      config = config(adapter)

      assert {:ok, %{binding: binding}} =
               Bindings.put_binding(nil, adapter, "shared", %{
                 routing_mode: :sender_personal_assistant,
                 config: config
               })

      assert binding.agent_uid == nil
      assert binding.filters == %{"cel" => "signal.channel.kind == 'im_dm'"}
      assert binding.unmatched_sender_policy == :manual_review
      assert {:ok, saved_config} = Bindings.binding_config(binding, config_module(adapter))
      namespace = config_module(adapter).subject_namespace(saved_config)

      context =
        AdapterContext.new(
          binding_id: binding.id,
          agent_uid: nil,
          binding_name: binding.name,
          adapter: adapter
        )

      consumer = inbound(adapter).chat_consumer(context, saved_config)

      for {external, chat, index} <- [{"U1", "D1", 1}, {"U2", "D2", 2}] do
        %{principal: human} = human_fixture(%{email: "member#{index}@example.com"})
        provider_author_fixture(human.uid, external, %{provider: namespace})
        assert is_nil(Principals.personal_assistant(human.uid))
        event = message(adapter, external, chat, index, :dm)

        assert {:ok, [%{status: :accepted, inbound_batch: batch}]} =
                 inbound(adapter).handle_message_receive("message", event, [consumer])

        assistant = Principals.personal_assistant(human.uid)
        assert batch.agent_uid == assistant.uid
        assert batch.binding_id == binding.id
        assert Ankole.AgentWorkers.get_agent_worker!(assistant.uid)

        assert {:ok, %{signal: signal}} =
                 InboundBatches.finalize_inbound_batch_by_id(batch.id, now: batch.available_at)

        assert signal.agent_uid == assistant.uid
        assert signal.human_uid == human.uid
        assert signal.reply_binding_id == binding.id

        assert {:ok, intent} =
                 Repo.transact(fn ->
                   Delivery.commit_in_tx(%{
                     agent_uid: assistant.uid,
                     binding_id: binding.id,
                     binding_name: binding.name,
                     outbound_key: "reply-#{index}",
                     source_signal_id: signal.id,
                     operation: :post,
                     conversation_id: signal.conversation_id,
                     payload: %{"text" => "Hello #{index}"},
                     fallback_visible_text: "Hello #{index}",
                     idempotency_key: "reply-#{index}"
                   })
                 end)

        assert {:ok, %{status: :sent, binding_id: id}} =
                 Delivery.Dispatch.dispatch_by_key(
                   assistant.uid,
                   binding.name,
                   intent.outbound_key
                 )

        assert id == binding.id
        assert_receive {:sent, _, body}
        assert body =~ "Hello"
        assert body =~ chat

        assert {:ok, [%{status: :recorded, external_ref: reacted}]} =
                 inbound(adapter).handle_reaction_created(
                   "reaction",
                   reaction(adapter, external, chat, index),
                   [consumer]
                 )

        assert reacted.reactions["thumbs_up"] == [external]

        assert {:ok, [%{status: :accepted, signal: clicked}]} =
                 inbound(adapter).handle_card_action(
                   "action",
                   action(adapter, external, chat, index, signal.id),
                   [consumer]
                 )

        assert clicked.agent_uid == assistant.uid
        assert clicked.reply_binding_id == binding.id
        assert clicked.human_uid == human.uid

        if adapter == "lark" do
          assert {:ok, %{}} = Ankole.Plugins.LarkAdapter.RuntimeEnv.resolve_worker_env(binding)
        end

        assert {:ok, [%{deleted_mirror_entries: 1}]} =
                 inbound(adapter).handle_message_removed(
                   "removed",
                   removed(adapter, chat, index),
                   [consumer]
                 )
      end

      # A saved/custom filter cannot widen the routing mode beyond direct messages.
      assert {:ok, %{binding: unrestricted}} =
               Bindings.put_binding(nil, adapter, "shared", %{
                 routing_mode: :sender_personal_assistant,
                 config: config,
                 filters: %{"cel" => "true"}
               })

      assert unrestricted.filters == %{"cel" => "true"}
      consumer = inbound(adapter).chat_consumer(context, saved_config)
      %{principal: group_member} = human_fixture()
      provider_author_fixture(group_member.uid, "U3", %{provider: namespace})

      assert {:ok, [%{status: :filtered}]} =
               inbound(adapter).handle_message_receive(
                 "message",
                 message(adapter, "U3", "G3", 3, :group),
                 [consumer]
               )

      assert is_nil(Principals.personal_assistant(group_member.uid))

      %{principal: guest} = human_fixture(%{membership: :guest})
      provider_author_fixture(guest.uid, "U4", %{provider: namespace})

      assert {:ok, [%{status: :ignored_non_member}]} =
               inbound(adapter).handle_message_receive(
                 "message",
                 message(adapter, "U4", "D4", 4, :dm),
                 [consumer]
               )

      assert is_nil(Principals.personal_assistant(guest.uid))

      # Admission notices use the fixed system service, independently of Brain.
      assert {:ok, %{uid: "system"} = system} = Principals.system_principal()

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               inbound(adapter).handle_message_receive(
                 "message",
                 message(adapter, "U5", "D5", 5, :dm),
                 [consumer]
               )

      assert notice =
               Repo.get_by(Ankole.Conversations.Delivery.Intent,
                 agent_uid: system.uid,
                 binding_id: binding.id
               )

      assert notice.fallback_visible_text =~ "Ankole Console"
    end
  end

  defp config_module("lark"), do: Ankole.Plugins.LarkAdapter.Config
  defp config_module("slack"), do: Ankole.Plugins.SlackAdapter.Config
  defp inbound("lark"), do: Ankole.Plugins.LarkAdapter.Inbound
  defp inbound("slack"), do: Ankole.Plugins.SlackAdapter.Inbound

  defp config("lark"),
    do: %{
      "appID" => "cli_shared",
      "appSecret" => "test-secret",
      "identityProvider" => ":standalone"
    }

  defp config("slack"),
    do: %{
      "botToken" => "xoxb-shared",
      "appToken" => "xapp-shared",
      "identityProvider" => ":standalone"
    }

  defp message("lark", sender, chat, index, kind) do
    %FeishuOpenAPI.Event{
      id: "ev_#{index}",
      type: "im.message.receive_v1",
      raw: %{},
      content: %{
        "sender" => %{"sender_type" => "user", "sender_id" => %{"open_id" => sender}},
        "message" => %{
          "message_id" => "om_#{index}",
          "chat_id" => chat,
          "chat_type" => if(kind == :dm, do: "p2p", else: "group"),
          "message_type" => "text",
          "content" => Ankole.JSON.encode!(%{"text" => "Hello"})
        }
      }
    }
  end

  defp message("slack", sender, chat, index, kind) do
    %SlackOpenAPI.Event{
      id: "ev_#{index}",
      type: "message",
      team_id: "T1",
      api_app_id: "A1",
      raw: %{},
      content: %{
        "user" => sender,
        "channel" => chat,
        "channel_type" => if(kind == :dm, do: "im", else: "channel"),
        "ts" => "1793440000.00000#{index}",
        "text" => "Hello"
      }
    }
  end

  defp reaction("lark", sender, chat, index) do
    %FeishuOpenAPI.Event{
      id: "reaction-#{index}",
      raw: %{},
      content: %{
        "operator" => %{"open_id" => sender},
        "message" => %{"message_id" => "om_#{index}", "chat_id" => chat},
        "reaction_type" => %{"emoji_type" => "THUMBSUP"}
      }
    }
  end

  defp reaction("slack", sender, chat, index) do
    %SlackOpenAPI.Event{
      id: "reaction-#{index}",
      raw: %{},
      content: %{
        "user" => sender,
        "reaction" => "thumbsup",
        "item" => %{"type" => "message", "channel" => chat, "ts" => "1793440000.00000#{index}"}
      }
    }
  end

  defp action("lark", sender, chat, index, source_id) do
    %FeishuOpenAPI.Event{
      id: "action-#{index}",
      raw: %{},
      content: %{
        "operator" => %{"open_id" => sender},
        "context" => %{"open_chat_id" => chat, "open_message_id" => "om_#{index}"},
        "action" => %{"name" => "approve", "value" => %{"sourceSignalId" => source_id}}
      }
    }
  end

  defp action("slack", sender, chat, index, source_id) do
    %SlackOpenAPI.Event{
      id: "action-#{index}",
      raw: %{},
      content: %{
        "user" => %{"id" => sender},
        "container" => %{"channel_id" => chat, "message_ts" => "1793440000.00000#{index}"},
        "actions" => [
          %{"action_id" => "approve", "value" => Torque.encode!(%{"sourceSignalId" => source_id})}
        ]
      }
    }
  end

  defp removed("lark", chat, index) do
    %FeishuOpenAPI.Event{
      id: "removed-#{index}",
      raw: %{},
      content: %{
        "message_id" => "om_#{index}",
        "chat_id" => chat
      }
    }
  end

  defp removed("slack", chat, index) do
    %SlackOpenAPI.Event{
      id: "removed-#{index}",
      raw: %{},
      content: %{
        "deleted_ts" => "1793440000.00000#{index}",
        "channel" => chat
      }
    }
  end
end
