defmodule Ankole.Plugins.DiscordAdapterTest.FakeGateway do
  @moduledoc """
  The smallest Discord gateway that answers the handshake: HELLO, then READY
  and the test's dispatch events for an IDENTIFY, and RESUMED for a RESUME. It
  forwards every received payload to the test so the test can read what the
  session owner actually sent.
  """

  @behaviour WebSock

  @impl true
  def init(state) do
    send(state.test, {:gateway, :connected})
    {:push, {:text, encode(%{"op" => 10, "d" => %{"heartbeat_interval" => 300}})}, state}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    payload = Torque.decode!(text)
    send(state.test, {:gateway, payload})

    case payload["op"] do
      2 -> {:push, [ready(state) | Enum.map(state.events, &frame/1)], state}
      6 -> {:push, resume_replay(state, payload["d"]["seq"]), state}
      1 -> {:push, {:text, encode(%{"op" => 11, "d" => nil})}, state}
      _other -> {:ok, state}
    end
  end

  # Discord replays every event after the resume sequence, then marks the
  # caught-up point with RESUMED.
  defp resume_replay(state, seq) do
    replayed = Enum.filter(state.events, &(is_integer(&1["s"]) and &1["s"] > seq))

    Enum.map(replayed, &frame/1) ++
      [frame(%{"op" => 0, "t" => "RESUMED", "s" => nil, "d" => %{}})]
  end

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    send(state.test, {:gateway, :closed})
    :ok
  end

  defp ready(state) do
    frame(%{
      "op" => 0,
      "t" => "READY",
      "s" => 1,
      "d" => %{
        "session_id" => "sess-1",
        "resume_gateway_url" => state.resume_url,
        "user" => %{"id" => "77", "username" => "AnkoleBot"}
      }
    })
  end

  defp frame(payload), do: {:text, encode(payload)}
  defp encode(payload), do: Torque.encode!(payload)
end

defmodule Ankole.Plugins.DiscordAdapterTest.GatewayPlug do
  @moduledoc false

  alias Ankole.Plugins.DiscordAdapterTest.FakeGateway

  def init(opts), do: opts
  def call(conn, opts), do: WebSockAdapter.upgrade(conn, FakeGateway, opts, [])
end

defmodule Ankole.Plugins.DiscordAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Plugins.DiscordAdapter

  alias Ankole.Plugins.DiscordAdapter.{
    ActionToken,
    Client,
    Config,
    ConnectionOwner,
    ConnectionReconciler,
    ConnectionSupervisor,
    Dispatcher,
    Emoji,
    ErrorPolicy,
    Gateway,
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

  @bot %{id: "77", username: "AnkoleBot"}
  @dm_channel "discord:77:channel:501"

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
    test "keeps two Agents' same-name bindings on distinct config keys" do
      key = Config.binding_config_key("agent-a", "main")
      assert key =~ ~r/\Asignals_gateway\.discord\.bindings\.[a-f0-9]{64}\z/
      refute key == Config.binding_config_key("agent-b", "main")

      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()

      assert {:ok, %{binding: first_binding}} =
               SignalsGateway.put_binding(first.uid, "discord", "main", %{
                 "config" => %{"botToken" => "bot.first-secret"}
               })

      assert {:ok, %{binding: second_binding}} =
               SignalsGateway.put_binding(second.uid, "discord", "main", %{
                 "config" => %{"botToken" => "bot.second-secret"}
               })

      assert {:ok, %{"botToken" => "bot.first-secret"}} =
               SignalsGateway.Bindings.stored_binding_config(first_binding)

      assert {:ok, %{"botToken" => "bot.second-secret"}} =
               SignalsGateway.Bindings.stored_binding_config(second_binding)
    end

    test "declares one consumer IM adapter with the complete gateway capability set" do
      assert DiscordAdapter.plugin_id() == "discord-adapter"
      assert [declaration] = DiscordAdapter.adapter_declarations()
      assert declaration.id == "discord"
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
      assert Enum.all?(DiscordAdapter.app_config_patterns(), & &1.encrypted)
    end

    test "validates the one required secret and redacts it from client inspection" do
      assert {:ok, %{"botToken" => "bot.secret-value"}} =
               Config.validate_binding_config(%{"botToken" => "bot.secret-value"})

      assert {:error, {:missing, "botToken"}} = Config.validate_binding_config(%{})

      client = Client.new("bot.secret-value")
      refute inspect(client) =~ "secret-value"
      assert inspect(client) =~ "[REDACTED]"

      runtime = %Config.Runtime{bot_token: "bot.secret-value"}
      refute inspect(runtime) =~ "secret-value"
      assert inspect(runtime) =~ "[REDACTED]"

      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{"code" => "discord_delivery_unknown"}}} =
               ErrorPolicy.normalize_delivery_result({:error, :discord_send_uncertain})
    end
  end

  describe "message chunking" do
    test "counts astral and ZWJ text in UTF-16 units without splitting graphemes" do
      prefix = String.duplicate("😀", 995)
      suffix = "👨‍👩‍👧‍👦tail"
      text = prefix <> suffix

      assert [^prefix, ^suffix] = assert_utf16_chunks(text, 2_000)
    end

    test "splits an oversized grapheme only between code points" do
      text = "😀" <> String.duplicate("\u0301", 1_999)
      assert [^text] = String.graphemes(text)

      assert [first, second] = assert_utf16_chunks(text, 2_000)
      assert utf16_units(first) == 2_000
      assert utf16_units(second) == 1
    end
  end

  describe "gateway protocol" do
    test "asks for the privileged message-content intent only when the application allows it" do
      assert Gateway.intents(false) == 512 + 1_024 + 4_096 + 8_192
      assert Gateway.intents(true) == Gateway.intents(false) + 32_768

      assert Gateway.message_content_flag?(262_144)
      assert Gateway.message_content_flag?(524_288)
      refute Gateway.message_content_flag?(4_096)
      refute Gateway.message_content_flag?(nil)

      assert %{"d" => %{"intents" => intents, "shard" => [0, 1]}} =
               Gateway.identify("bot.secret-value", false, {0, 1})

      assert intents == Gateway.intents(false)
    end

    test "classifies every payload the session owner acts on" do
      assert {:dispatch, "MESSAGE_CREATE", 7, %{"id" => "1"}} =
               Gateway.classify(%{
                 "op" => 0,
                 "t" => "MESSAGE_CREATE",
                 "s" => 7,
                 "d" => %{"id" => "1"}
               })

      assert {:hello, 41_250} =
               Gateway.classify(%{"op" => 10, "d" => %{"heartbeat_interval" => 41_250}})

      assert :heartbeat_ack = Gateway.classify(%{"op" => 11})
      assert :heartbeat_request = Gateway.classify(%{"op" => 1, "d" => nil})
      assert :reconnect = Gateway.classify(%{"op" => 7, "d" => nil})
      assert {:invalid_session, true} = Gateway.classify(%{"op" => 9, "d" => true})
      assert {:invalid_session, false} = Gateway.classify(%{"op" => 9, "d" => false})
      assert :unknown = Gateway.classify(%{"op" => 4})
    end

    test "separates close codes that need an operator from the ones that resume" do
      assert {:fatal, :authentication_failed} = Gateway.close_action(4_004)
      assert {:fatal, :disallowed_intents} = Gateway.close_action(4_014)
      assert :session_invalid = Gateway.close_action(4_007)
      assert :session_invalid = Gateway.close_action(4_009)
      assert :resumable = Gateway.close_action(4_000)
      assert :resumable = Gateway.close_action(nil)

      assert Gateway.socket_url("wss://gateway.discord.gg/") ==
               "wss://gateway.discord.gg/?v=10&encoding=json"
    end
  end

  describe "REST client and preflight" do
    test "keeps the fractional rate-limit delay and never repeats the token" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/v10/users/@me" ->
            Req.Test.json(conn, %{"id" => "77", "username" => "AnkoleBot"})

          "/api/v10/channels/501/messages" ->
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{
              "code" => 20_028,
              "message" => "rejected token bot.rate-secret",
              "retry_after" => 0.25
            })
        end
      end)

      client = test_client("bot.rate-secret")
      assert {:ok, %{"id" => "77"}} = Client.current_user(client)

      assert {:error, %Client.Error{kind: :api, status: 429, code: 20_028} = error} =
               Client.post(client, "/channels/501/messages", %{"content" => "hi"})

      assert error.retry_after == 1
      assert error.message == "rejected token [REDACTED]"
    end

    test "keeps an authentication failure in an operator-visible blocked state" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"code" => 0, "message" => "401: Unauthorized bot.auth-secret"})
      end)

      stub_client_opts()
      key = {"auth-agent", "discord-auth"}

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.auth-secret"}, [
                 consumer(elem(key, 0), elem(key, 1))
               ])

      assert eventually(fn -> ConnectionOwner.status(owner).state == :blocked end),
             inspect(ConnectionOwner.status(owner))

      assert %{blocked_reason: :authentication_failed, last_error: %{status: 401}} =
               ConnectionOwner.status(owner)

      refute inspect(ConnectionOwner.status(owner)) =~ "auth-secret"
      assert :ok = ConnectionSupervisor.stop(key)
    end

    test "waits for Discord's retry_after before repeating a rate-limited preflight" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(attempts, &(&1 + 1))

        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"message" => "rate limited", "retry_after" => 2})
      end)

      stub_client_opts()
      key = {"rate-agent", "discord-rate"}

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.rate-secret"}, [
                 consumer(elem(key, 0), elem(key, 1))
               ])

      on_exit(fn -> ConnectionSupervisor.stop(key) end)

      assert eventually(fn -> ConnectionOwner.status(owner).last_error[:status] == 429 end)
      Process.sleep(1_100)
      assert Agent.get(attempts, & &1) == 1
    end

    test "uses the message-content permission and replaces the owner on token rotation" do
      stub_preflight()
      stub_client_opts()

      consumer = consumer("owner-agent", "discord-main")

      assert {:ok, first} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.first-secret"}, [consumer])

      assert eventually(fn -> ConnectionOwner.status(first).bot_id == "77" end)

      assert %{
               message_content_intent?: false,
               state: :starting
             } = ConnectionOwner.status(first)

      assert {:ok, second} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.rotated-secret"}, [
                 consumer
               ])

      refute second == first
      refute Process.alive?(first)
      assert :ok = ConnectionSupervisor.stop({"owner-agent", "discord-main"})
    end
  end

  describe "gateway session" do
    test "keeps an ignored sequence behind a slow durable event across reconnect" do
      parent = self()
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-session", %{
                 "config" => %{"botToken" => "bot.session-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      accepted =
        dm_message("9500", "durable message")
        |> Map.put("attachments", [
          %{
            "id" => "sequence-attachment",
            "url" => "https://cdn.discord.test/attachments/sequence/file.txt",
            "filename" => "file.txt",
            "size" => 4
          }
        ])

      port =
        start_fake_gateway([
          dispatch(2, "MESSAGE_CREATE", accepted),
          dispatch(3, "MESSAGE_UPDATE", %{"id" => "9502"}),
          %{"op" => 7, "d" => nil}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/v10/users/@me" ->
            Req.Test.json(conn, %{"id" => "77", "username" => "AnkoleBot"})

          "/api/v10/applications/@me" ->
            Req.Test.json(conn, %{"id" => "app-77", "flags" => 262_144})

          "/api/v10/gateway/bot" ->
            Req.Test.json(conn, %{"url" => "ws://127.0.0.1:#{port}", "shards" => 1})

          "/attachments/sequence/file.txt" ->
            send(parent, {:sequence_download_started, self()})

            receive do
              :finish_sequence_download -> Req.Test.transport_error(conn, :timeout)
            end
        end
      end)

      stub_client_opts()

      key = {agent.uid, "discord-session"}

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.session-secret"}, [
                 consumer(agent.uid, "discord-session", %{"botToken" => "bot.session-secret"})
               ])

      on_exit(fn -> ConnectionSupervisor.stop(key) end)

      assert_receive {:gateway, :connected}, 3_000

      assert_receive {:gateway, %{"op" => 2, "d" => %{"intents" => intents, "shard" => [0, 1]}}},
                     3_000

      assert intents == Gateway.intents(true)

      assert_receive {:sequence_download_started, download_process}, 3_000

      assert %{sequence: 1, pending_events: 2} = ConnectionOwner.status(owner)
      assert_receive {:gateway, :closed}, 3_000
      send(download_process, :finish_sequence_download)

      assert eventually(fn -> ConnectionOwner.status(owner).sequence == 3 end),
             inspect(ConnectionOwner.status(owner))

      assert_receive {:gateway, %{"op" => 6, "d" => %{"seq" => 3, "session_id" => "sess-1"}}},
                     5_000

      assert eventually(fn ->
               Repo.get_by(Entry, signal_channel_id: @dm_channel, source_entry_id: accepted["id"]) !=
                 nil
             end)

      assert %{state: :running, session?: true, message_content_intent?: true} =
               ConnectionOwner.status(owner)
    end

    test "sheds replayable events at the pending bound and recovers through resume replay" do
      parent = self()
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-bound", %{
                 "config" => %{"botToken" => "bot.bound-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      blocked =
        dm_message("9600", "blocked head")
        |> Map.put("attachments", [
          %{
            "id" => "bound-attachment",
            "url" => "https://cdn.discord.test/attachments/bound/file.txt",
            "filename" => "file.txt",
            "size" => 4
          }
        ])

      backlog =
        Enum.map(3..6, fn seq ->
          dispatch(seq, "MESSAGE_CREATE", dm_message("96#{seq}", "backlog #{seq}"))
        end)

      port = start_fake_gateway([dispatch(2, "MESSAGE_CREATE", blocked) | backlog])

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/v10/users/@me" ->
            Req.Test.json(conn, %{"id" => "77", "username" => "AnkoleBot"})

          "/api/v10/applications/@me" ->
            Req.Test.json(conn, %{"id" => "app-77", "flags" => 0})

          "/api/v10/gateway/bot" ->
            Req.Test.json(conn, %{"url" => "ws://127.0.0.1:#{port}", "shards" => 1})

          "/attachments/bound/file.txt" ->
            send(parent, {:bound_download_started, self()})

            receive do
              :finish_bound_download -> Req.Test.transport_error(conn, :timeout)
            end
        end
      end)

      Application.put_env(:ankole, Config,
        client_opts: [base_url: "https://discord.test/api/v10", plug: {Req.Test, __MODULE__}],
        max_pending_events: 4
      )

      key = {agent.uid, "discord-bound"}

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.bound-secret"}, [
                 consumer(agent.uid, "discord-bound", %{"botToken" => "bot.bound-secret"})
               ])

      on_exit(fn -> ConnectionSupervisor.stop(key) end)

      assert_receive {:bound_download_started, download_process}, 3_000

      # The fifth backlog event hits the bound of four: the owner keeps only
      # the in-flight head, sheds the replayable rest, and reconnects.
      assert_receive {:gateway, :closed}, 3_000
      assert %{pending_events: 1, sequence: 1} = ConnectionOwner.status(owner)

      send(download_process, :finish_bound_download)

      # The resume starts from the confirmed sequence and the replay restores
      # the shed events, so the backlog drains once ingress moves again.
      assert_receive {:gateway, %{"op" => 6, "d" => %{"seq" => 2, "session_id" => "sess-1"}}},
                     5_000

      assert eventually(fn -> ConnectionOwner.status(owner).sequence == 6 end),
             inspect(ConnectionOwner.status(owner))

      assert %{state: :running, session?: true, pending_events: 0} =
               ConnectionOwner.status(owner)

      assert eventually(fn ->
               Repo.get_by(Entry,
                 signal_channel_id: @dm_channel,
                 source_entry_id: List.last(backlog)["d"]["id"]
               ) != nil
             end)
    end

    test "acknowledges a component while an earlier attachment is still downloading" do
      parent = self()
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-fast-ack", %{
                 "config" => %{"botToken" => "bot.fast-ack-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      slow_message =
        dm_message("9503", "read this")
        |> Map.put("attachments", [
          %{
            "id" => "slow-attachment",
            "url" => "https://cdn.discord.test/attachments/slow/file.txt",
            "filename" => "file.txt",
            "size" => 4
          }
        ])

      interaction = interaction_event("stale-action")["interaction"]

      port =
        start_fake_gateway([
          dispatch(2, "MESSAGE_CREATE", slow_message),
          dispatch(3, "INTERACTION_CREATE", interaction)
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/v10/users/@me" ->
            Req.Test.json(conn, %{"id" => "77", "username" => "AnkoleBot"})

          "/api/v10/applications/@me" ->
            Req.Test.json(conn, %{"id" => "app-77", "flags" => 0})

          "/api/v10/gateway/bot" ->
            Req.Test.json(conn, %{"url" => "ws://127.0.0.1:#{port}", "shards" => 1})

          "/attachments/slow/file.txt" ->
            send(parent, {:attachment_download_started, self()})

            receive do
              :finish_attachment_download -> Req.Test.transport_error(conn, :timeout)
            end

          "/api/v10/interactions/interaction-77/interaction-token/callback" ->
            send(parent, :interaction_acknowledged)
            Req.Test.json(conn, %{})
        end
      end)

      stub_client_opts()
      key = {agent.uid, "discord-fast-ack"}

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(%{"botToken" => "bot.fast-ack-secret"}, [
                 consumer(agent.uid, "discord-fast-ack", %{
                   "botToken" => "bot.fast-ack-secret"
                 })
               ])

      on_exit(fn -> ConnectionSupervisor.stop(key) end)

      assert_receive {:attachment_download_started, download_process}, 3_000
      assert_receive :interaction_acknowledged, 2_500
      send(download_process, :finish_attachment_download)
      assert eventually(fn -> ConnectionOwner.status(owner).sequence == 3 end)
    end
  end

  describe "inbound projection" do
    test "projects direct and addressed guild messages with stable identities" do
      consumer = consumer("agent-a", "discord-main")

      assert {:ok, dm} =
               Inbound.normalize_message_create(
                 message_event(dm_message("100", "hello")),
                 consumer
               )

      assert dm.explicit
      assert dm.signal_channel_id == @dm_channel
      assert dm.provider_thread_id == @dm_channel
      assert dm.channel.kind == :im_dm
      assert dm.author["provider"] == "discord"
      assert dm.author["platform_subject"] == "100"
      refute Map.has_key?(dm.author, "email")

      mentioned =
        guild_message("101", "<@77> deploy now")
        |> Map.put("mentions", [%{"id" => "77", "username" => "AnkoleBot"}])

      assert {:ok, addressed} =
               Inbound.normalize_message_create(message_event(mentioned), consumer)

      assert addressed.explicit
      assert addressed.text == "deploy now"
      assert addressed.channel.kind == :im_group
      assert [%{"targets_current_agent" => true}] = addressed.mentions
      assert addressed.signal_channel_id == "discord:77:channel:900"

      replied =
        guild_message("102", "sounds good")
        |> Map.put("type", 19)
        |> Map.put("referenced_message", %{"id" => "800", "author" => %{"id" => "77"}})

      assert {:ok, reply} = Inbound.normalize_message_create(message_event(replied), consumer)
      assert reply.explicit
      assert reply.reply_to_source_entry_id == "800"

      overheard = guild_message("103", "unrelated chatter")

      assert {:ok, unaddressed} =
               Inbound.normalize_message_create(message_event(overheard), consumer)

      refute unaddressed.explicit
    end

    test "rejects the bot's own messages, other bots, webhooks, and system notices" do
      consumer = consumer("agent-a", "discord-main")

      own = dm_message("100", "hello") |> put_in(["author", "id"], "77")

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_create(message_event(own), consumer)

      other_bot = dm_message("100", "hello") |> put_in(["author", "bot"], true)

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_create(message_event(other_bot), consumer)

      webhook = guild_message("100", "hello") |> Map.put("webhook_id", "9001")

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_create(message_event(webhook), consumer)

      system = dm_message("100", "hello") |> Map.put("type", 1)

      assert {:ignore, :unsupported_sender} =
               Inbound.normalize_message_create(message_event(system), consumer)
    end

    test "skips a guild message that arrives empty without the message-content intent" do
      consumer = consumer("agent-a", "discord-main")
      stripped = guild_message("101", nil) |> Map.put("content", "")

      assert {:ignore, :empty_message} =
               Inbound.normalize_message_create(message_event(stripped), consumer)

      for unsupported <- [
            Map.put(stripped, "sticker_items", [%{"id" => "sticker-1"}]),
            Map.put(stripped, "embeds", [%{"type" => "rich"}]),
            stripped
            |> Map.put("content", "<@77>")
            |> Map.put("mentions", [%{"id" => "77"}])
          ] do
        assert {:ignore, :empty_message} =
                 Inbound.normalize_message_create(message_event(unsupported), consumer)
      end

      with_attachment =
        Map.put(stripped, "attachments", [
          %{
            "id" => "att-1",
            "url" => "https://cdn.discord.test/attachments/1/2/notes.txt",
            "filename" => "notes.txt",
            "size" => 12
          }
        ])

      assert {:ok, %{attachments: [_attachment], text: nil}} =
               Inbound.normalize_message_create(message_event(with_attachment), consumer)
    end

    test "keeps an over-limit attachment fact but never invents a readable path" do
      consumer = consumer("agent-a", "discord-main")

      message =
        dm_message("100", nil)
        |> Map.put("attachments", [
          %{
            "id" => "att-big",
            "url" => "https://cdn.discord.test/attachments/1/2/archive.zip",
            "filename" => "archive.zip",
            "content_type" => "application/zip",
            "size" => 26 * 1024 * 1024
          }
        ])

      assert {:ok, %{attachments: [attachment]}} =
               Inbound.normalize_message_create(message_event(message), consumer)

      assert attachment["materialization_state"] == "provider_download_limit"
      assert attachment["restriction"] =~ "25 MB"
      refute Map.has_key?(attachment, "attachment_id")
      refute Map.has_key?(attachment, "agent_computer_path")
      refute Map.has_key?(attachment, "user_files_relative_path")
    end

    test "assigns the durable attachment ID before writing an admitted file to user-files" do
      parent = self()
      %{principal: agent} = agent_fixture()
      stub_client_opts()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:discord_request, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "attachment")
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-media", %{
                 "config" => %{"botToken" => "bot.media-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      route = "discord-inbound-attachment-#{System.unique_integer([:positive])}"
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
        dm_message("9002", nil)
        |> Map.put("attachments", [
          %{
            "id" => "att-report",
            "url" => "https://cdn.discord.test/attachments/1/2/report.txt",
            "filename" => "report.txt",
            "content_type" => "text/plain",
            "size" => 10
          }
        ])

      assert {:ok, [result]} =
               Inbound.handle_message_receive("MESSAGE_CREATE", message_event(message), [
                 consumer(agent.uid, "discord-media", %{"botToken" => "bot.media-secret"})
               ])

      assert %Entry{attachments: [attachment]} = result.signal_entry
      assert_received {:discord_request, "/attachments/1/2/report.txt"}
      assert is_integer(attachment["attachment_id"])
      assert attachment["materialization_state"] == "complete"

      expected_relative = "inbox/#{attachment["attachment_id"]}/report.txt"
      assert attachment["user_files_relative_path"] == expected_relative

      assert attachment["agent_computer_path"] ==
               "/agents/#{agent.uid}/user-files/#{expected_relative}"

      expected_lane = "/user_files/#{agent.uid}/user-files/#{expected_relative}"
      assert_receive {:materialized_attachment_path, ^expected_lane}
    end

    test "deduplicates a message the gateway replays after a resume" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-replay", %{
                 "config" => %{"botToken" => "bot.replay-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      event = message_event(dm_message("9070", "deliver once"))
      discord_consumer = consumer(agent.uid, "discord-replay")

      assert {:ok, [_first]} =
               Inbound.handle_message_receive("MESSAGE_CREATE", event, [discord_consumer])

      assert {:ok, [_replayed]} =
               Inbound.handle_message_receive("MESSAGE_CREATE", event, [discord_consumer])

      assert Repo.aggregate(Entry, :count) == 1
    end

    test "folds Discord reactions into the mirrored entry and keys custom emoji by id" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-reactions", %{
                 "config" => %{"botToken" => "bot.reaction-secret"},
                 "unmatched_sender_policy" => "create_standalone"
               })

      message = dm_message("9001", "react here")
      discord_consumer = consumer(agent.uid, "discord-reactions")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("MESSAGE_CREATE", message_event(message), [
                 discord_consumer
               ])

      added =
        reaction_event(message["id"], "9001", %{"id" => nil, "name" => "👍"}, 1)

      assert {:ok, [%{status: :mirrored}]} =
               Inbound.handle_reaction_created("MESSAGE_REACTION_ADD", added, [discord_consumer])

      entry = Repo.get_by!(Entry, signal_channel_id: @dm_channel, source_entry_id: message["id"])
      assert entry.reactions == %{"👍" => ["9001"]}
      assert entry.raw_reaction_keys == %{"👍" => "👍"}

      assert {:ok, [%{status: :mirrored}]} =
               Inbound.handle_reaction_deleted(
                 "MESSAGE_REACTION_REMOVE",
                 reaction_event(message["id"], "9001", %{"id" => nil, "name" => "👍"}, 2),
                 [discord_consumer]
               )

      assert Repo.get_by!(Entry, signal_channel_id: @dm_channel, source_entry_id: message["id"]).reactions ==
               %{}

      assert {:ok, [%{status: :mirrored}]} =
               Inbound.handle_reaction_created(
                 "MESSAGE_REACTION_ADD",
                 reaction_event(message["id"], "9001", %{"id" => nil, "name" => "👍"}, 3),
                 [discord_consumer]
               )

      assert Repo.get_by!(Entry, signal_channel_id: @dm_channel, source_entry_id: message["id"]).reactions ==
               %{"👍" => ["9001"]}

      assert Emoji.reaction_key(%{"id" => "555", "name" => "partyparrot"}) ==
               {"discord_custom:555", "partyparrot:555"}

      assert Emoji.path_segment("thumbsup") == "%F0%9F%91%8D"
      assert Emoji.path_segment("partyparrot:555") == "partyparrot:555"
    end

    test "ignores a reaction the bot itself added" do
      discord_consumer = consumer("agent-a", "discord-main")
      own = reaction_event("900", "77", %{"name" => "👍"})

      assert {:ok, [%{status: :ignored_unsupported_sender}]} =
               Inbound.handle_reaction_created("MESSAGE_REACTION_ADD", own, [discord_consumer])
    end
  end

  describe "identity admission" do
    test "manual review maps a Discord user to an existing human principal" do
      %{principal: agent} = agent_fixture()
      %{principal: human} = human_fixture()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-review", %{
                 "config" => %{"botToken" => "bot.review-secret"},
                 "unmatched_sender_policy" => "manual_review"
               })

      discord_consumer = consumer(agent.uid, "discord-review")
      held = message_event(dm_message("7001", "let me in"))

      assert {:ok, [%{status: status}]} =
               Inbound.handle_message_receive("MESSAGE_CREATE", held, [discord_consumer])

      refute status == :accepted
      assert Repo.aggregate(Entry, :count) == 0

      assert {:ok, _identity} =
               MappingRequests.bind_subject(human.uid, %{
                 provider: "discord",
                 external_id: "7001"
               })

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "MESSAGE_CREATE",
                 message_event(dm_message("7001", "let me in")),
                 [discord_consumer]
               )

      assert {:ok, matched} = Principals.resolve_platform_subject("discord", "7001")
      assert matched.uid == human.uid
    end

    test "one bot token can belong to only one enabled binding" do
      %{principal: first_agent} = agent_fixture()
      %{principal: second_agent} = agent_fixture()

      attrs = %{"config" => %{"botToken" => "bot.exclusive-secret"}}

      assert {:ok, _binding} =
               SignalsGateway.put_binding(first_agent.uid, "discord", "discord-one", attrs)

      assert {:error, {:discord_bot_token_already_bound, first_uid, "discord-one"}} =
               SignalsGateway.put_binding(second_agent.uid, "discord", "discord-two", attrs)

      assert first_uid == first_agent.uid
      assert {:ok, _disabled} = SignalsGateway.disable_binding(first_agent.uid, "discord-one")

      assert {:ok, _binding} =
               SignalsGateway.put_binding(second_agent.uid, "discord", "discord-two", attrs)
    end

    test "the reconciler stops the owner after its binding is disabled" do
      %{principal: agent} = agent_fixture()
      config = %{"botToken" => "bot.disable-secret"}

      stub_preflight()
      stub_client_opts()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-disabled", %{
                 "config" => config
               })

      assert {:ok, owner} =
               ConnectionSupervisor.ensure_started(config, [
                 consumer(agent.uid, "discord-disabled", config)
               ])

      assert eventually(fn -> ConnectionOwner.status(owner).bot_id == "77" end)
      assert {:ok, _binding} = SignalsGateway.disable_binding(agent.uid, "discord-disabled")
      assert %{stopped: 1, errors: []} = ConnectionReconciler.reconcile_once()
      refute Process.alive?(owner)
    end
  end

  describe "actions and outbound" do
    test "checkpoints one mutable reply and edits the same Discord message" do
      parent = self()
      %{principal: agent} = agent_fixture()
      stub_client_opts()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:discord_request, conn.method, conn.request_path, Torque.decode!(raw_body)})

        case {conn.method, conn.request_path} do
          {"POST", "/api/v10/channels/501/messages"} ->
            Req.Test.json(conn, %{
              "id" => "900",
              "timestamp" => "2026-08-23T00:00:00.000000+00:00"
            })

          {"PATCH", "/api/v10/channels/501/messages/900"} ->
            Req.Test.json(conn, %{
              "id" => "900",
              "edited_timestamp" => "2026-08-23T00:00:01.000000+00:00"
            })
        end
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-preview", %{
                 "config" => %{"botToken" => "bot.preview-secret"}
               })

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(agent.uid, "discord-preview", %{
          source_event_id: "preview-event",
          signal_channel_id: @dm_channel,
          source_entry_id: "50",
          channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
          text: "hello",
          explicit: true,
          author: %{principal_uid: "human-a", id: "7001"},
          provider_time: base_time()
        })

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

      assert first.reply_preview_checkpoint["adapter"] == "discord"
      assert_received {:discord_request, "POST", "/api/v10/channels/501/messages", post_body}

      assert post_body["allowed_mentions"] == %{
               "parse" => [],
               "replied_user" => false
             }

      updated = ReplyPresentation.replace_answer(presentation, "final draft")

      assert {:ok, second} =
               ReplyPreview.update(%{
                 request
                 | presentation: updated,
                   checkpoint: first.reply_preview_checkpoint
               })

      assert second.created_source_entry_id == "900"

      assert_received {:discord_request, "PATCH", "/api/v10/channels/501/messages/900",
                       patch_body}

      assert patch_body["allowed_mentions"] == post_body["allowed_mentions"]
    end

    test "stops automatic retry when Discord created a reply before local ownership failed" do
      %{principal: agent} = agent_fixture()
      stub_client_opts()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-preview-partial", %{
                 "config" => %{"botToken" => "bot.preview-partial-secret"}
               })

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(agent.uid, "discord-preview-partial", %{
          source_event_id: "preview-partial-event",
          signal_channel_id: @dm_channel,
          source_entry_id: "51",
          channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
          text: "hello",
          explicit: true,
          author: %{principal_uid: "human-a", id: "7001"},
          provider_time: base_time()
        })

      Req.Test.stub(__MODULE__, fn conn ->
        event
        |> Ecto.Changeset.change(reply_preview_source_entry_id: "different-provider-message")
        |> Repo.update!()

        Req.Test.json(conn, %{"id" => "901"})
      end)

      request = %Request{
        actor_event: event,
        presentation:
          ReplyPresentation.new(state: "working")
          |> ReplyPresentation.replace_answer("draft"),
        checkpoint: nil,
        subject_uid: "human-a",
        conversation_id: "conversation-a",
        mode: :working
      }

      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{"code" => "discord_delivery_unknown"}}} = ReplyPreview.update(request)
    end

    test "classifies a rejected later chunk behind a delivered first chunk as partial delivery" do
      %{principal: agent} = agent_fixture()
      stub_client_opts()

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-preview-chunks", %{
                 "config" => %{"botToken" => "bot.preview-chunks-secret"}
               })

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(agent.uid, "discord-preview-chunks", %{
          source_event_id: "preview-chunks-event",
          signal_channel_id: @dm_channel,
          source_entry_id: "52",
          channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
          text: "hello",
          explicit: true,
          author: %{principal_uid: "human-a", id: "7001"},
          provider_time: base_time()
        })

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            Req.Test.json(conn, %{"id" => "910"})

          _later ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"code" => 50_035, "message" => "Invalid Form Body"})
        end
      end)

      request = %Request{
        actor_event: event,
        presentation:
          ReplyPresentation.new(state: "working")
          |> ReplyPresentation.replace_answer(String.duplicate("x", 2_500)),
        checkpoint: nil,
        subject_uid: "human-a",
        conversation_id: "conversation-a",
        mode: :working
      }

      # A bare 400 normalizes as permanent, but the first chunk is already
      # visible, so the half-rendered reply must reach an operator instead.
      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{"code" => "discord_delivery_unknown"}}} = ReplyPreview.update(request)
    end

    test "uses a custom_id within the Discord limit and restores the action from a checkpoint" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "discord-action", :ignore, adapter: "discord")
      stub_client_opts()

      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:discord_request, conn.method, conn.request_path})
        Req.Test.json(conn, %{})
      end)

      %{actor_event: %ActorEvent{} = event} =
        emit_addressed_actor_event(agent.uid, "discord-action", %{
          source_event_id: "event-1",
          signal_channel_id: @dm_channel,
          source_entry_id: "50",
          channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
          text: "hello",
          explicit: true,
          author: %{principal_uid: "human-a", id: "7001"},
          provider_time: base_time()
        })

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
        %{"message_id" => "900", "messages" => [%{"index" => 0, "message_id" => "900"}]}
        |> ReplyInteractionState.initialize(presentation, base_time())

      assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
      assert {:ok, token} = ActionToken.encode(event.id, 0, hd(presentation["actions"]))
      assert byte_size(token) <= 100

      assert {:ok, value} = ActionToken.resolve(token, agent.uid, "discord-action", "900")
      assert value["version"] == "ankole.interactive_output.action.v1"
      assert value["sourceActorEventId"] == event.id
      assert value["optionValue"] == "approved"

      # A forged event id must fail as an invalid token, not raise in the
      # event lookup.
      assert {:error, :invalid_callback_token} =
               ActionToken.resolve(
                 "dc1:not-a-uuid:0:AAAAAAAAAAA",
                 agent.uid,
                 "discord-action",
                 "900"
               )

      changed =
        put_in(
          checkpoint,
          ["presentation", "actions", Access.at(0), "option_value"],
          "changed-after-render"
        )

      assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, changed)

      assert {:error, :invalid_callback_action} =
               ActionToken.resolve(token, agent.uid, "discord-action", "900")

      assert {:ok, _event} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
      assert {:ok, [%{"components" => components}]} = Presentation.render(presentation, event.id)

      assert get_in(components, [Access.at(0), "components", Access.at(0)]) == %{
               "type" => 2,
               "style" => 1,
               "label" => "Approve",
               "custom_id" => token
             }

      %{principal: operator} = human_fixture()

      assert {:ok, _identity} =
               MappingRequests.bind_subject(operator.uid, %{
                 provider: "discord",
                 external_id: "7001"
               })

      event = interaction_event(token)

      assert :ok =
               Dispatcher.acknowledge(
                 "INTERACTION_CREATE",
                 event["interaction"],
                 test_client("bot.action-secret")
               )

      assert {:ok, [%{status: :accepted, actor_event: action_event}]} =
               Inbound.handle_card_action("INTERACTION_CREATE", event, [
                 consumer(agent.uid, "discord-action", %{"botToken" => "bot.action-secret"})
               ])

      assert action_event.type == "signal.action.invoked"

      assert_received {:discord_request, "POST",
                       "/api/v10/interactions/interaction-77/interaction-token/callback"}
    end

    test "builds every declared outbound operation against the original adapter channel" do
      base = %OutboxEntry{
        agent_uid: "agent-a",
        binding_name: "discord-main",
        outbound_key: "out-1",
        operation: :post,
        signal_channel_id: @dm_channel,
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

      assert {:ok, [%{method: :post, path: "/channels/501/messages", body: body}]} =
               Outbox.requests_for_outbox(base)

      assert body == %{
               "content" => "hello",
               "allowed_mentions" => %{"parse" => [], "replied_user" => false}
             }

      assert {:ok, [%{method: :put, path: reaction_path}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :reaction_add,
                   target_source_entry_id: "42",
                   payload: %{"reaction_key" => "thumbsup"}
               })

      assert reaction_path == "/channels/501/messages/42/reactions/%F0%9F%91%8D/@me"

      assert {:ok, [%{path: custom_reaction_path}]} =
               Outbox.requests_for_outbox(%{
                 base
                 | operation: :reaction_add,
                   target_source_entry_id: "42",
                   payload: %{
                     "reaction_key" => "discord_custom:555",
                     "raw_reaction_key" => "partyparrot:555"
                   }
               })

      assert custom_reaction_path ==
               "/channels/501/messages/42/reactions/partyparrot:555/@me"

      assert {:error, :invalid_discord_channel_id} =
               Outbox.requests_for_outbox(%{base | signal_channel_id: "telegram:77:chat:501"})
    end

    test "sends a reply attachment as one message and never as a placeholder text" do
      register_file_reader(
        "discord-outbound-#{System.unique_integer([:positive])}",
        "report bytes"
      )

      outbox = %OutboxEntry{
        agent_uid: "agent-a",
        binding_name: "discord-main",
        outbound_key: "attachment-1",
        operation: :reply,
        signal_channel_id: @dm_channel,
        reply_to_source_entry_id: "42",
        payload: %{
          "attachments" => [
            %{
              "user_files_relative_path" => "outbox/report.pdf",
              "name" => "report.pdf",
              "mime_type" => "application/pdf"
            }
          ]
        },
        fallback_visible_text: ""
      }

      assert {:ok, [request]} = Outbox.requests_for_outbox(outbox)
      assert request.path == "/channels/501/messages"

      assert request.files == [
               %{
                 content: "report bytes",
                 filename: "report.pdf",
                 content_type: "application/pdf"
               }
             ]

      refute Map.has_key?(request.body, "content")

      assert request.body["allowed_mentions"] == %{
               "parse" => [],
               "replied_user" => false
             }

      assert request.body["message_reference"] == %{
               "message_id" => "42",
               "fail_if_not_exists" => false
             }

      assert {:ok, [%{body: %{"content" => "here it is"}, files: [_file]}]} =
               Outbox.requests_for_outbox(%{outbox | fallback_visible_text: "here it is"})

      assert {:error, :outbound_attachment_path_missing} =
               Outbox.requests_for_outbox(%{
                 outbox
                 | payload: %{"attachments" => [%{"name" => "report.pdf"}]}
               })

      assert {:error, {:reply_delivery, :operator_action_required, %{"code" => code}}} =
               ErrorPolicy.normalize_delivery_result({:error, :outbound_attachment_path_missing})

      assert code == "attachment_path_missing"
    end

    test "returns unknown when a non-idempotent provider send has an uncertain result" do
      %{principal: agent} = agent_fixture()
      stub_client_opts()

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-unknown", %{
                 "config" => %{"botToken" => "bot.uncertain-secret"}
               })

      assert :unknown =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "discord-unknown",
                 outbound_key: "unknown-1",
                 operation: :post,
                 signal_channel_id: @dm_channel,
                 payload: %{},
                 fallback_visible_text: "hello"
               })
    end

    test "returns unknown when a successful create has no message ID" do
      %{principal: agent} = agent_fixture()
      stub_client_opts()
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-missing-id", %{
                 "config" => %{"botToken" => "bot.missing-id-secret"}
               })

      assert :unknown =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "discord-missing-id",
                 outbound_key: "missing-id-1",
                 operation: :post,
                 signal_channel_id: @dm_channel,
                 payload: %{},
                 fallback_visible_text: "hello"
               })
    end

    test "keeps an uncertain edit retryable because repeating it is safe" do
      %{principal: agent} = agent_fixture()
      stub_client_opts()
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-edit-retry", %{
                 "config" => %{"botToken" => "bot.edit-secret"}
               })

      assert {:error, {:reply_delivery, :retryable, %{"code" => "discord_api_error"}}} =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "discord-edit-retry",
                 outbound_key: "edit-retry-1",
                 operation: :edit,
                 target_source_entry_id: "900",
                 signal_channel_id: @dm_channel,
                 payload: %{},
                 fallback_visible_text: "safe retry"
               })
    end

    test "returns unknown after one chunk succeeds and a later chunk is uncertain" do
      %{principal: agent} = agent_fixture()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      stub_client_opts()

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> Req.Test.json(conn, %{"id" => "1"})
          _later -> Req.Test.transport_error(conn, :timeout)
        end
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-partial", %{
                 "config" => %{"botToken" => "bot.partial-secret"}
               })

      assert :unknown =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "discord-partial",
                 outbound_key: "partial-1",
                 operation: :post,
                 signal_channel_id: @dm_channel,
                 payload: %{},
                 fallback_visible_text: String.duplicate("x", 2_001)
               })

      assert Agent.get(attempts, & &1) == 2
    end

    test "treats a message another operator already deleted as the outcome the outbox asked for" do
      parent = self()
      %{principal: agent} = agent_fixture()
      stub_client_opts()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:discord_request, conn.method, conn.request_path})

        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"code" => 10_008, "message" => "Unknown Message"})
      end)

      assert {:ok, _binding} =
               SignalsGateway.put_binding(agent.uid, "discord", "discord-delete", %{
                 "config" => %{"botToken" => "bot.delete-secret"}
               })

      assert {:ok, _result} =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "discord-delete",
                 outbound_key: "delete-1",
                 operation: :delete,
                 target_source_entry_id: "900",
                 signal_channel_id: @dm_channel,
                 payload: %{},
                 fallback_visible_text: ""
               })

      assert_received {:discord_request, "DELETE", "/api/v10/channels/501/messages/900"}

      assert {:ok, _result} =
               Outbox.send(%OutboxEntry{
                 agent_uid: agent.uid,
                 binding_name: "discord-delete",
                 outbound_key: "edit-missing-1",
                 operation: :edit,
                 target_source_entry_id: "900",
                 signal_channel_id: @dm_channel,
                 payload: %{},
                 fallback_visible_text: String.duplicate("x", 2_001)
               })

      assert_received {:discord_request, "PATCH", "/api/v10/channels/501/messages/900"}
      refute_received {:discord_request, "POST", _path}
    end
  end

  defp consumer(agent_uid, binding_name, config \\ %{"botToken" => "test-only-token"}) do
    Inbound.chat_consumer(
      AdapterContext.new(
        agent_uid: agent_uid,
        binding_name: binding_name,
        adapter: "discord",
        user_name: "Discord"
      ),
      config
    )
  end

  defp message_event(message), do: %{"message" => message, "bot" => @bot}

  defp reaction_event(message_id, user_id, emoji, sequence \\ 1) do
    %{
      "bot" => @bot,
      "gateway_session_id" => "test-session",
      "gateway_sequence" => sequence,
      "reaction" => %{
        "message_id" => message_id,
        "channel_id" => "501",
        "user_id" => user_id,
        "emoji" => emoji
      }
    }
  end

  defp interaction_event(custom_id) do
    %{
      "bot" => @bot,
      "interaction" => %{
        "id" => "interaction-77",
        "token" => "interaction-token",
        "type" => 3,
        "channel_id" => "501",
        "data" => %{"custom_id" => custom_id, "component_type" => 2},
        "message" => %{"id" => "900"},
        "user" => %{"id" => "7001", "username" => "ada"}
      }
    }
  end

  defp dm_message(author_id, content) do
    %{
      "id" => Integer.to_string(System.unique_integer([:positive])),
      "channel_id" => "501",
      "timestamp" => "2026-08-23T00:00:00.000000+00:00",
      "type" => 0,
      "content" => content,
      "author" => %{"id" => author_id, "username" => "ada#{author_id}", "global_name" => "Ada"}
    }
  end

  defp guild_message(author_id, content) do
    dm_message(author_id, content)
    |> Map.merge(%{"channel_id" => "900", "guild_id" => "600"})
  end

  defp test_client(token) do
    Client.new(token, base_url: "https://discord.test/api/v10", plug: {Req.Test, __MODULE__})
  end

  defp stub_client_opts do
    Application.put_env(:ankole, Config,
      client_opts: [base_url: "https://discord.test/api/v10", plug: {Req.Test, __MODULE__}]
    )
  end

  # The preflight is the only part of the gateway handshake that speaks HTTP.
  # The default gateway URL points at a closed port so the owner stays in
  # `starting` and its reconnect backoff never runs a second attempt inside one
  # test that does not want a session.
  defp stub_preflight(opts \\ []) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/v10/users/@me" ->
          Req.Test.json(conn, %{"id" => "77", "username" => "AnkoleBot"})

        "/api/v10/applications/@me" ->
          Req.Test.json(conn, %{
            "id" => "app-77",
            "flags" => Keyword.get(opts, :flags, 0)
          })

        "/api/v10/gateway/bot" ->
          Req.Test.json(conn, %{
            "url" => Keyword.get(opts, :gateway_url, "ws://127.0.0.1:1"),
            "shards" => 1
          })
      end
    end)
  end

  defp dispatch(sequence, type, data),
    do: %{"op" => 0, "t" => type, "s" => sequence, "d" => data}

  defp start_fake_gateway(events) do
    port = free_port()

    start_supervised!(
      {Bandit,
       plug:
         {Ankole.Plugins.DiscordAdapterTest.GatewayPlug,
          %{test: self(), events: events, resume_url: "ws://127.0.0.1:#{port}"}},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1},
       startup_log: false}
    )

    port
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ifaddr: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # The outbox reads attachment bytes out of the agent's user-files lane, so a
  # ready worker has to answer the read frames for that lane.
  defp register_file_reader(route, content) do
    worker = insert_ready_worker!(route)
    route_auth = %{route: route, worker_id: worker.worker_id}
    wire = Ankole.Kernel.zstd_compress_block(content, 3)

    :ok =
      Broker.register_local_worker(route, fn
        {:file_transfer_lane, [protocol, "READ_OPEN", transfer_id, path, _fingerprint]} ->
          FileTransferLane.handle_worker_frame(route_auth, [
            protocol,
            "READ_READY",
            transfer_id,
            path,
            u64(byte_size(content)),
            ""
          ])

        {:file_transfer_lane, [protocol, "CREDIT", transfer_id, _credit]} ->
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
      worker_id: "discord-worker-#{System.unique_integer([:positive])}",
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

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, _attempts) when not is_function(fun, 0), do: false
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
