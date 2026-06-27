defmodule Ankole.SignalsGatewayTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Ankole.Actors
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorInputTypes
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  @base_time ~U[2026-06-23 08:00:00.000000Z]

  defmodule ModuleOutboxAdapter do
    @moduledoc false

    @behaviour Ankole.SignalsGateway.OutboxAdapter

    def capabilities, do: [:post_entry]

    def send(_outbox), do: {:ok, %{provider_entry_id: "module-adapter-msg"}}
  end

  defp actor_commit_opts(opts) do
    Keyword.merge(
      [
        llm_turn_id: Ecto.UUID.generate(),
        activation_uid:
          "test-activation-" <> Integer.to_string(System.unique_integer([:positive])),
        actor_epoch: 1,
        revision: 0
      ],
      opts
    )
  end

  defp emit_addressed_actor_input(agent_uid, binding_name, entry, now \\ @base_time) do
    assert {:ok, %{status: :accepted, inbound_batch: batch}} =
             SignalsGateway.emit_entry(agent_uid, binding_name, entry, now: now)

    assert {:ok, results} =
             SignalsGateway.finalize_due_inbound_batches(
               now: DateTime.add(now, 600, :millisecond)
             )

    actor_input =
      Enum.find_value(results, fn
        %{actor_input: %ActorInput{} = input} -> input
        _result -> nil
      end)

    assert %ActorInput{} = actor_input
    %{inbound_batch: batch, actor_input: actor_input}
  end

  describe "binding policy and actor handoff" do
    test "ignore skips unaddressed group entries without mirroring or waking" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{status: :ignored}} =
               SignalsGateway.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(InboundBatch, :count) == 1
    end

    test "record_only mirrors unaddressed group entries without actor input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      assert {:ok, %{status: :recorded, signal_entry: entry}} =
               SignalsGateway.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert entry.signal_channel_id == "lark:chat:group-a"
      assert entry.provider_entry_id == "msg-1"
      assert entry.search_text == "hello"
      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(InboundBatch, :count) == 1
    end

    test "may_intervene mirrors and finalizes a delayed ambient observation input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               SignalsGateway.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      due_at = DateTime.add(@base_time, 15_000, :millisecond)

      assert batch.available_at == due_at
      assert Repo.aggregate(ActorInput, :count) == 0

      assert {:ok, [%{status: :accepted, actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(now: due_at)

      assert input.type == "im.message.may_intervene"
      assert input.available_at == due_at

      assert [%{"speaker" => "Alice", "sent_at" => sent_at, "text" => "hello"}] =
               input.payload["data"]["observed_messages"]

      assert sent_at == DateTime.to_iso8601(@base_time)
      assert input.sender_key == nil
    end

    test "may_intervene entries in the same room and thread finalize as one ambient input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: first}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   ingress_event_id: "evt-ambient-first",
                   provider_entry_id: "msg-ambient-first",
                   text: "first"
                 }),
                 now: @base_time
               )

      second_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{inbound_batch: second}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   ingress_event_id: "evt-ambient-second",
                   provider_entry_id: "msg-ambient-second",
                   text: "second"
                 }),
                 now: second_at
               )

      due_at = DateTime.add(second_at, 15_000, :millisecond)
      merged = Repo.get!(InboundBatch, first.id)

      assert first.id == second.id
      assert Repo.aggregate(ActorInput, :count) == 0
      assert merged.available_at == due_at

      assert [
               %{"provider_entry_id" => "msg-ambient-first", "text" => "first"},
               %{"provider_entry_id" => "msg-ambient-second", "text" => "second"}
             ] = merged.entries

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(now: due_at)

      assert [
               %{"speaker" => "Alice", "text" => "first"},
               %{"speaker" => "Alice", "text" => "second"}
             ] = input.payload["data"]["observed_messages"]

      assert Actors.list_ready_inputs(
               agent.uid,
               SignalsGateway.signal_session_id("lark:chat:group-a"),
               due_at
             )
             |> Enum.map(& &1.id) == [input.id]
    end

    test "DM and structured mentions are explicit even when group policy is ignore" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{inbound_batch: dm_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   ingress_event_id: "evt-dm",
                   provider_entry_id: "dm-msg-1",
                   signal_channel_id: "lark:dm:alice-agent",
                   channel: %{kind: :im_dm, reply_mode: :entry},
                   text: "dm"
                 }),
                 now: @base_time
               )

      assert {:ok, [%{actor_input: dm_input}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 600, :millisecond)
               )

      assert dm_input.type == "im.message.addressed"
      assert dm_batch.mode == "addressed"

      assert {:ok, %{inbound_batch: mention_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   ingress_event_id: "evt-mention",
                   provider_entry_id: "msg-mention",
                   text: "@Agent do this",
                   mentions: [%{kind: :agent, structured: true, agent_uid: agent.uid}]
                 }),
                 now: @base_time
               )

      assert {:ok, [%{actor_input: mention_input}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 600, :millisecond)
               )

      assert mention_input.type == "im.message.addressed"
      assert mention_batch.mode == "addressed"
    end

    test "pending clarify lookup can route an unmentioned group reply as explicit input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{status: :accepted, inbound_batch: batch}} =
               SignalsGateway.emit_entry(agent.uid, "lark-main", group_entry(),
                 now: @base_time,
                 clarify_lookup: fn _binding, fact ->
                   fact.signal_channel_id == "lark:chat:group-a" and
                     fact.sender_key == "alice"
                 end
               )

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 600, :millisecond)
               )

      assert input.type == "im.message.addressed"
      assert batch.mode == "addressed"
      assert Repo.aggregate(ActorInput, :count) == 1
    end

    test "non-IM entries need code-defined actor input type instead of addressed IM fallback" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:error, :missing_actor_input_type} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_input_type: nil}),
                 now: @base_time
               )

      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(SignalEntry, :count) == 0
    end

    test "unavailable bindings do not accept ingress even when enabled" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore, unavailable_reason: "adapter missing")

      assert {:error, {:binding_unavailable, "adapter missing"}} =
               SignalsGateway.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)
    end

    test "CEL binding filters can admit or filter ingress before mirror and actor input writes" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "bot", :ignore,
        filters: %{"cel" => "signal.channel.id == 'lark:chat:allowed'"}
      )

      assert {:ok, %{status: :filtered}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0

      %{actor_input: input} =
        emit_addressed_actor_input(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            ingress_event_id: "evt-allowed",
            signal_channel_id: "lark:chat:allowed",
            provider_entry_id: "msg-allowed"
          })
        )

      assert input.signal_channel_id == "lark:chat:allowed"
      assert Repo.aggregate(SignalEntry, :count) == 1
      assert Repo.aggregate(ActorInput, :count) == 1
    end

    test "CEL binding filters expose common CEL functions" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "bot", :ignore,
        filters: %{
          "cel" =>
            "signal.entry.sender_key.startsWith('lark:user:') && signal.entry.sender_key.matches('^lark:user:[a-z]+$') && signal.entry.text.contains('hello') && ['lark:chat:allowed'].contains(signal.channel.id)"
        }
      )

      assert {:ok, %{status: :filtered}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   sender_key: "lark:user:bob",
                   text: "goodbye",
                   signal_channel_id: "lark:chat:allowed"
                 }),
                 now: @base_time
               )

      %{actor_input: input} =
        emit_addressed_actor_input(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            sender_key: "lark:user:alice",
            ingress_event_id: "evt-cel-functions",
            signal_channel_id: "lark:chat:allowed",
            provider_entry_id: "msg-cel-functions"
          })
        )

      assert input.sender_key == "lark:user:alice"
    end

    test "invalid CEL filters fail before durable writes" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "runtime-error", :ignore,
        filters: %{"cel" => "signal.entry.missing == true"}
      )

      assert {:error, {:invalid_binding_filter, reason}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "runtime-error",
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert reason =~ "signal filter execution failed"

      assert {:error, changeset} =
               SignalsGateway.upsert_binding(%{
                 agent_uid: agent.uid,
                 name: "bad-shape",
                 adapter: "lark",
                 config_ref: "app-config://bad-shape",
                 filters: %{"eq" => %{"signal_channel_id" => "x"}},
                 unaddressed_group_message_policy: :ignore
               })

      assert %{filters: [_]} = errors_on(changeset)

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0
    end

    test "adapter context exposes a host-owned platform subject bridge" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      context =
        AdapterContext.new(
          agent_uid: agent.uid,
          binding_name: "lark-main",
          adapter: "lark",
          user_name: "Lark Bot"
        )

      assert {:ok, observed} =
               AdapterContext.observe_platform_subject(context, %{
                 external_id: "ou_alice",
                 uid: "Alice",
                 display_name: "Alice",
                 metadata: %{"tenant_key" => "tenant-a"}
               })

      assert observed.principal.uid == "alice"
      assert observed.identity.provider == "lark-main"
      assert observed.identity.external_id == "ou_alice"
    end

    test "entry ingress enriches known platform subject authors with principal uid" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      platform_subject_fixture(
        provider: "bot",
        external_id: "ou_alice",
        uid: "Alice",
        display_name: "Alice"
      )

      %{actor_input: input} =
        emit_addressed_actor_input(
          agent.uid,
          "bot",
          group_entry(%{
            ingress_event_id: "evt-known-author",
            provider_entry_id: "msg-known-author",
            explicit: true,
            author: %{platform_subject: "ou_alice", display_name: "Alice"}
          })
        )

      assert input.sender_key == "alice"

      assert %SignalEntry{author: %{"principal_uid" => "alice", "platform_subject" => "ou_alice"}} =
               Repo.get_by!(SignalEntry,
                 signal_channel_id: "lark:chat:group-a",
                 provider_entry_id: "msg-known-author"
               )
    end
  end

  describe "mirror identity and route-scoped delivery" do
    test "same physical channel and entry share one mirror row while actor input remains per binding" do
      %{principal: agent_a} = agent_fixture()
      %{principal: agent_b} = agent_fixture()
      binding_fixture(agent_a.uid, "bot-a", :ignore)
      binding_fixture(agent_b.uid, "bot-b", :ignore)

      explicit = group_entry(%{explicit: true})

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent_a.uid, "bot-a", explicit, now: @base_time)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(
                 agent_b.uid,
                 "bot-b",
                 %{explicit | ingress_event_id: "evt-1-b"},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert Repo.aggregate(SignalEntry, :count) == 1

      assert {:ok, [%{actor_input: _input_a}, %{actor_input: _input_b}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert Repo.aggregate(ActorInput, :count) == 2

      assert Repo.aggregate(
               from(input in ActorInput, where: input.agent_uid == ^agent_a.uid),
               :count
             ) == 1

      assert Repo.aggregate(
               from(input in ActorInput, where: input.agent_uid == ^agent_b.uid),
               :count
             ) == 1
    end

    test "different provider entry ids are not guessed as duplicates" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   ingress_event_id: "evt-2",
                   provider_entry_id: "provider-specific-msg-2"
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(SignalEntry, :count) == 2
    end
  end

  describe "commands and inbound IM batching" do
    test "internal timer facts append actor input without provider mirror" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "internal:timers", :ignore, adapter: "internal")

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_internal(
                 agent.uid,
                 "internal:timers",
                 %{
                   ingress_event_id: "timer-fire-1",
                   session_id: "daily-reset:agent",
                   timer_id: "daily-reset",
                   type: "timer.fired",
                   internal: %{reason: "daily_reset"}
                 },
                 now: @base_time
               )

      assert input.type == "timer.fired"
      assert input.signal_channel_id == nil
      assert input.session_id == "daily-reset:agent"
      assert input.payload["source"] == "internal://internal:timers/daily-reset:agent"
      assert input.payload["subject"] == "timers:daily-reset"
      assert input.payload["data"]["internal"] == %{"reason" => "daily_reset"}
      assert Repo.aggregate(SignalEntry, :count) == 0
    end

    test "recognized commands stay typed command events and steer maps through code" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_input: compress_input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, text: "/compress release notes"}),
                 now: @base_time
               )

      assert compress_input.type == "command.compress"
      assert compress_input.payload["type"] == "command.compress"
      assert compress_input.payload["data"]["command"]["argsText"] == "release notes"
      assert ActorInputTypes.command_runtime_policy("command.compress") == :worker_turn
      assert ActorInputTypes.command_runtime_policy("command.stop") == :control_now
      assert ActorInputTypes.command_runtime_policy("command.retry") == :control_now
      assert ActorInputTypes.command_runtime_policy("command.new") == :control_now
      assert ActorInputTypes.command_runtime_policy("command.steer") == :checkpoint_nudge

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   ingress_event_id: "evt-steer-1",
                   provider_entry_id: "msg-steer-1",
                   text: "/steer be concise"
                 }),
                 now: @base_time
               )

      assert input.type == "command.steer"
      assert input.available_at == @base_time
      assert input.payload["type"] == "command.steer"
      assert input.payload["data"]["command"]["argsText"] == "be concise"
      refute Map.has_key?(input.payload["data"]["command"], "status")
      assert ActorInputTypes.consumption_path("command.steer") == :addressed_im
    end

    test "unsupported commands and full-width slash remain normal addressed text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: undo_input} =
        emit_addressed_actor_input(
          agent.uid,
          "bot",
          group_entry(%{explicit: true, text: "/undo"})
        )

      assert undo_input.type == "im.message.addressed"

      %{actor_input: full_width_input} =
        emit_addressed_actor_input(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            ingress_event_id: "evt-full-width",
            provider_entry_id: "msg-full-width",
            text: "／steer"
          }),
          DateTime.add(@base_time, 1, :second)
        )

      assert full_width_input.type == "im.message.addressed"
    end

    test "command parser handles leading structured mentions, full-width spaces, digits, and multiline args" do
      assert {:ok, command} =
               Commands.classify("@Agent /retry\u3000１２\nbecause it failed",
                 strip_leading_structured_mention: true,
                 structured_mention_prefixes: ["@Agent"]
               )

      assert command["name"] == "retry"
      assert command["argsText"] == "12\nbecause it failed"
      refute Map.has_key?(command, "status")
    end

    test "addressed IM entries close as sender-scoped actor input batches" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      alice = %{principal_uid: "alice", id: "provider-alice", display_name: "Alice"}
      bob = %{principal_uid: "bob", id: "provider-bob", display_name: "Bob"}

      for {event_id, entry_id, author, offset, text} <- [
            {"evt-a1", "msg-a1", alice, 0, "first"},
            {"evt-a2", "msg-a2", alice, 100, "second"},
            {"evt-b1", "msg-b1", bob, 200, "third"}
          ] do
        assert {:ok, %{status: :accepted}} =
                 SignalsGateway.emit_entry(
                   agent.uid,
                   "bot",
                   group_entry(%{
                     explicit: true,
                     ingress_event_id: event_id,
                     provider_entry_id: entry_id,
                     author: author,
                     text: text
                   }),
                   now: DateTime.add(@base_time, offset, :millisecond)
                 )
      end

      assert Repo.aggregate(ActorInput, :count) == 1

      rows =
        ActorInput
        |> order_by([input], asc: input.inserted_at)
        |> Repo.all()

      assert Enum.map(rows, & &1.sender_key) == ["alice"]

      [alice_input] = rows
      assert alice_input.provider_entry_id == "msg-a2"
      assert get_in(alice_input.payload, ["data", "entry", "text"]) == "first\nsecond"

      assert [
               %{"provider_entry_id" => "msg-a1", "text" => "first"},
               %{"provider_entry_id" => "msg-a2", "text" => "second"}
             ] = get_in(alice_input.payload, ["data", "entries"])

      assert [%InboundBatch{mode: "addressed", requester_sender_key: "bob"} = bob_batch] =
               InboundBatch
               |> where([batch], batch.batch_state == "open")
               |> Repo.all()

      due_at = DateTime.add(@base_time, 800, :millisecond)

      assert {:ok, [%{actor_input: bob_input}]} =
               SignalsGateway.finalize_due_inbound_batches(now: due_at)

      assert bob_input.provider_entry_id == "msg-b1"
      assert bob_batch.id == Repo.get!(InboundBatch, bob_batch.id).id
    end

    test "neutral batch upgrades only the final same-sender run when bot is mentioned" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      alice = %{principal_uid: "alice", id: "provider-alice", display_name: "Alice"}
      bob = %{principal_uid: "bob", id: "provider-bob", display_name: "Bob"}

      assert {:ok, %{status: :ignored}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-alice-neutral",
                   provider_entry_id: "msg-alice-neutral",
                   author: alice,
                   text: "alice aside"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :ignored}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-bob-neutral",
                   provider_entry_id: "msg-bob-neutral",
                   author: bob,
                   text: "bob context"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   ingress_event_id: "evt-bob-mention",
                   provider_entry_id: "msg-bob-mention",
                   author: bob,
                   text: "@Agent help",
                   mentions: [%{kind: :agent, structured: true, agent_uid: agent.uid}]
                 }),
                 now: DateTime.add(@base_time, 200, :millisecond)
               )

      assert addressed_batch.mode == "addressed"
      assert addressed_batch.requester_sender_key == "bob"

      due_at = DateTime.add(@base_time, 800, :millisecond)

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(now: due_at)

      assert get_in(input.payload, ["data", "entry", "text"]) == "bob context\n@Agent help"

      assert [
               %{"provider_entry_id" => "msg-bob-neutral"},
               %{"provider_entry_id" => "msg-bob-mention"}
             ] = get_in(input.payload, ["data", "entries"])

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "msg-alice-neutral"
             )
    end

    test "addressed text followed by attachment waits on the attachment window and merges" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{inbound_batch: first_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   ingress_event_id: "evt-text",
                   provider_entry_id: "msg-text",
                   text: "look at this"
                 }),
                 now: @base_time
               )

      attachment_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{inbound_batch: updated_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-image",
                   provider_entry_id: "msg-image",
                   text: "image",
                   attachments: [%{provider_ref: "lark:image:image-1", name: "chart.png"}]
                 }),
                 now: attachment_at
               )

      assert first_batch.id == updated_batch.id

      assert Repo.get!(InboundBatch, first_batch.id).available_at ==
               DateTime.add(attachment_at, 1_200, :millisecond)

      assert {:ok, []} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 1_100, :millisecond)
               )

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(attachment_at, 1_200, :millisecond)
               )

      assert get_in(input.payload, ["data", "entry", "text"]) == "look at this\nimage"

      assert [%{"provider_ref" => "lark:image:image-1", "name" => "chart.png"}] =
               get_in(input.payload, ["data", "entry", "attachments"])
    end

    test "single addressed message over the normal text budget is not split" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      long_text = String.duplicate("x", 4_500)

      assert {:ok, %{inbound_batch: batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   text: long_text
                 }),
                 now: @base_time
               )

      assert [%{"text" => ^long_text}] = batch.entries

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 2_000, :millisecond)
               )

      assert get_in(input.payload, ["data", "entry", "text"]) == long_text
      assert [_one_entry] = get_in(input.payload, ["data", "entries"])
    end
  end

  describe "entry removal lifecycle" do
    test "removal before receive writes tombstone and drops late receive" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "delete-1"}),
                 now: @base_time
               )

      assert Repo.aggregate(InputTombstone, :count) == 1

      assert {:ok, %{status: :dropped_tombstoned}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, ingress_event_id: "evt-late"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0
    end

    test "receive and delete use the same transaction-scoped advisory lock" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      lock_key = Enum.join(["lark:chat:group-a", "msg-1"], "|")
      parent = self()

      task =
        Task.async(fn ->
          Repo.transact(fn repo ->
            SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])
            send(parent, :lock_acquired)
            Process.sleep(200)
            {:ok, :released}
          end)
        end)

      assert_receive :lock_acquired, 1_000

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms >= 150
      assert {:ok, :released} = Task.await(task, 1_000)
    end

    test "removal while inbound batch is pending removes source entry without lifecycle wake" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted, inbound_batch: batch}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(ActorInput, :count) == 0
      assert batch.batch_state == "open"

      assert {:ok, %{updated_inbound_batches: 1, canceled_actor_inputs: 0, lifecycle_inputs: []}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "recall-1"}),
                 now: @base_time
               )

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0

      assert %InboundBatch{batch_state: "canceled", outcome: "canceled", entries: entries} =
               Repo.get!(InboundBatch, batch.id)

      assert entries == []
    end

    test "removal after actor commit appends deterministic lifecycle input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: original_input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _consumed} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 original_input.ingress_event_id,
                 actor_commit_opts(consumed_at: DateTime.add(@base_time, 1, :second))
               )

      assert {:ok, %{lifecycle_inputs: [lifecycle_input]}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "delete-consumed"}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert lifecycle_input.type == "signal.entry.removed"
      assert lifecycle_input.available_at == DateTime.add(@base_time, 2, :second)
      assert Repo.aggregate(SignalEntry, :count) == 0
    end

    test "actor commit rejects a actor input after a committed tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: original_input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "recall-before-commit"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert {:error, :actor_input_not_found} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 original_input.ingress_event_id,
                 actor_commit_opts(consumed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.aggregate(ActorInput, :count) == 0
    end

    test "actor commit rejects an existing actor input row when tombstone already exists" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: original_input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _tombstone} =
               %InputTombstone{}
               |> InputTombstone.changeset(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 signal_channel_id: "lark:chat:group-a",
                 provider_entry_id: "msg-1",
                 tombstoned_until: DateTime.add(@base_time, 1, :day)
               })
               |> Repo.insert()

      assert {:error, :actor_input_canceled} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 original_input.ingress_event_id,
                 actor_commit_opts(consumed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.aggregate(ActorInput, :count) == 1
    end

    test "removal of record_only entry only updates mirror and tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(), now: @base_time)

      assert {:ok, %{canceled_actor_inputs: 0, lifecycle_inputs: []}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "delete-record-only"}),
                 now: @base_time
               )

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0
    end
  end

  describe "provider mirror behavior" do
    test "older provider time does not overwrite newer mirror and reactions survive re-mirroring" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "new",
                   provider_time: DateTime.add(@base_time, 10, :second)
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :mirrored}} =
               SignalsGateway.emit_reaction(
                 agent.uid,
                 "bot",
                 %{
                   signal_channel_id: "lark:chat:group-a",
                   provider_entry_id: "msg-1",
                   reaction_key: "thumbsup",
                   raw_reaction_key: "👍",
                   actor_key: "alice"
                 },
                 now: @base_time
               )

      assert {:ok, %{status: :recorded}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-old",
                   text: "old",
                   provider_time: @base_time
                 }),
                 now: DateTime.add(@base_time, 20, :second)
               )

      entry =
        Repo.get_by!(SignalEntry,
          signal_channel_id: "lark:chat:group-a",
          provider_entry_id: "msg-1"
        )

      assert entry.text == "new"
      assert entry.reactions == %{"thumbsup" => ["alice"]}
      assert entry.raw_reaction_keys == %{"thumbsup" => "👍"}
    end

    test "unknown reactions are ignored" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :ignored_unknown_entry}} =
               SignalsGateway.emit_reaction(
                 agent.uid,
                 "bot",
                 %{
                   signal_channel_id: "missing-channel",
                   provider_entry_id: "missing-message",
                   reaction_key: "thumbsup",
                   actor_key: "alice"
                 },
                 now: @base_time
               )
    end

    test "sparse channel facts do not erase richer channel projection" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   channel: %{
                     kind: :im_group,
                     reply_mode: :entry,
                     name: "Operations",
                     title: "Ops Room",
                     metadata: %{topic: "incidents"}
                   }
                 }),
                 now: @base_time
               )

      assert {:ok, _} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "delete-sparse-channel",
                   channel: %{}
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      channel = Repo.get!(SignalChannel, "lark:chat:group-a")

      assert channel.kind == :im_group
      assert channel.reply_mode == :entry
      assert channel.name == "Operations"
      assert channel.title == "Ops Room"
      assert channel.metadata == %{"topic" => "incidents"}
    end

    test "attachments must already be materialized before gateway persistence" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:error, {:invalid_attachment_payload, preview}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [%{provider_ref: "lark:file:file-1", runtime: self()}]
                 }),
                 now: @base_time
               )

      assert preview["runtime"]["__type__"] == "pid"
      assert Repo.aggregate(SignalEntry, :count) == 0

      assert {:error, {:attachment_not_materialized, _attachment}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [%{file_path: "/tmp/host-only.png"}]
                 }),
                 now: @base_time
               )

      assert {:ok, %{signal_entry: entry}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [
                     %{provider_ref: "lark:file:file-1", name: "report.pdf"},
                     %{agent_computer_path: "/workspace/user-files/report.pdf"}
                   ]
                 }),
                 now: @base_time
               )

      assert entry.attachments == [
               %{"name" => "report.pdf", "provider_ref" => "lark:file:file-1"},
               %{"agent_computer_path" => "/workspace/user-files/report.pdf"}
             ]
    end
  end

  describe "durable JSON payload validation" do
    test "entry ingress rejects runtime values before mirror or actor input writes" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:error, {:invalid_json_payload, :metadata, :unsupported_runtime_value}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, metadata: %{"pid" => self()}}),
                 now: @base_time
               )

      assert Repo.aggregate(SignalEntry, :count) == 0
      assert Repo.aggregate(ActorInput, :count) == 0
    end

    test "internal input rejects runtime values before actor input write" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "internal:timers", :ignore, adapter: "internal")

      assert {:error, {:invalid_json_payload, :internal, :unsupported_runtime_value}} =
               SignalsGateway.emit_internal(
                 agent.uid,
                 "internal:timers",
                 %{
                   ingress_event_id: "timer-bad",
                   session_id: "daily-reset:agent",
                   type: "timer.fired",
                   internal: %{"pid" => self()}
                 },
                 now: @base_time
               )

      assert Repo.aggregate(ActorInput, :count) == 0
    end

    test "outbox commit rejects non JSON-serializable payload without inserting a row" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:error, changeset} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "bad-payload",
                 operation: :post,
                 payload: %{"pid" => self()},
                 fallback_visible_text: "bad"
               })

      assert "must be JSON-serializable object" <> _ =
               errors_on(changeset).payload |> List.first()

      assert Repo.aggregate(OutboxEntry, :count) == 0
    end
  end

  describe "outbox and background jobs" do
    test "actor consume can commit outbox intents in the same transaction" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _consumed} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 input.ingress_event_id,
                 actor_commit_opts(
                   consumed_at: DateTime.add(@base_time, 1, :second),
                   outbox_intents: [
                     %{
                       outbound_key: "actor-post-1",
                       operation: :post,
                       fallback_visible_text: "from actor"
                     }
                   ]
                 )
               )

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "actor-post-1"
        )

      assert outbox.status == :created
      assert outbox.signal_channel_id == "lark:chat:group-a"
      assert outbox.source_provider_entry_id == "msg-1"
    end

    test "actor consume rejects invalid outbox intents without a partial commit" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_input: input} =
        emit_addressed_actor_input(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:error, :invalid_outbox_intent} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 input.ingress_event_id,
                 actor_commit_opts(
                   consumed_at: DateTime.add(@base_time, 1, :second),
                   outbox_intents: [
                     %{
                       outbound_key: "valid-before-invalid",
                       operation: :post,
                       fallback_visible_text: "must rollback"
                     },
                     :not_an_intent
                   ]
                 )
               )

      assert Repo.get_by!(ActorInput,
               agent_uid: agent.uid,
               binding_name: "bot",
               ingress_event_id: input.ingress_event_id
             )

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "unsupported provider-visible reply marks outbox without faking mirror state" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:ok, _channel} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_input_type: "webhook.received"}),
                 now: @base_time
               )

      assert {:ok, outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "webhook",
                 outbound_key: "reply-1",
                 operation: :reply,
                 signal_channel_id: "webhook:incident-1",
                 source_provider_entry_id: "hook-1",
                 fallback_visible_text: "not possible"
               })

      assert outbox.status == :created

      assert {:ok, unsupported} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "webhook",
                 "reply-1",
                 %{capabilities: [:reply_entry]},
                 now: @base_time
               )

      assert unsupported.status == :unsupported

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "webhook:incident-1",
               provider_entry_id: "reply-1"
             )
    end

    test "unknown adapter capabilities fail before the outbox row enters sending" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "unknown-capability",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:error, {:unknown_outbox_capability, "made_up"}} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "unknown-capability",
                 %{
                   capabilities: ["post_entry", "made_up"],
                   send: fn _outbox -> {:ok, %{provider_entry_id: "must-not-send"}} end
                 },
                 now: @base_time
               )

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "unknown-capability"
        )

      assert outbox.status == :created
      assert outbox.platform_send_started_at == nil
    end

    test "module outbox adapters use the same normalized adapter contract" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _outbox} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "module-adapter",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "from module"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "module-adapter",
                 ModuleOutboxAdapter,
                 now: @base_time
               )

      assert succeeded.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "module-adapter-msg"
             ).text == "from module"
    end

    test "invalid adapter result is normalized, redacted, and recorded as send failure" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "invalid-adapter-result",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "invalid-adapter-result",
                 %{
                   capabilities: [:post_entry],
                   send: fn _outbox ->
                     {:unexpected,
                      %{
                        token: "top-secret",
                        nested: %{password: "hidden"},
                        body: String.duplicate("x", 1_200)
                      }}
                   end
                 },
                 now: @base_time
               )

      assert failed.status == :failed
      assert failed.last_error["reason"]["__type__"] == "tuple"
      assert failed.last_error["reason"]["items"] |> hd() == "invalid_adapter_result"

      adapter_result = failed.last_error["reason"]["items"] |> Enum.at(1)

      assert adapter_result["__type__"] == "tuple"

      payload = adapter_result["items"] |> Enum.at(1)

      assert payload["token"] == "[REDACTED]"
      assert payload["nested"]["password"] == "[REDACTED]"
      assert String.ends_with?(payload["body"], "...[truncated]")

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "invalid-adapter-result"
             )
    end

    test "successful post is mirrored only after adapter success and failure does not mirror" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _failed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-failed",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "failed"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-failed",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:error, :rate_limited} end},
                 now: @base_time
               )

      assert failed.status == :failed
      assert %DateTime{} = failed.next_attempt_at

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "post-failed"
             )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-ok",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-ok",
                 %{
                   capabilities: [:post_entry],
                   send: fn _outbox -> {:ok, %{provider_entry_id: "bot-msg-1"}} end
                 },
                 now: @base_time
               )

      assert succeeded.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "bot-msg-1"
             ).text ==
               "visible"
    end

    test "outbox send-start is durable before provider call" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-observe-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-observe-sending",
                 %{
                   capabilities: [:post_entry],
                   send: fn _outbox ->
                     outbox =
                       Repo.get_by!(OutboxEntry,
                         agent_uid: agent.uid,
                         binding_name: "bot",
                         outbound_key: "post-observe-sending"
                       )

                     assert outbox.status == :sending
                     assert %DateTime{} = outbox.platform_send_started_at

                     {:ok, %{provider_entry_id: "durable-send-msg"}}
                   end
                 },
                 now: @base_time
               )

      assert succeeded.status == :succeeded
    end

    test "post-like success without provider entry id materializes a stable local mirror id" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-without-provider-id",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      assert {:ok, succeeded} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-without-provider-id",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:ok, %{}} end},
                 now: @base_time
               )

      assert succeeded.status == :succeeded
      assert succeeded.provider_entry_id == "local-outbox:post-without-provider-id"

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "local-outbox:post-without-provider-id"
             ).text == "visible"
    end

    test "confirmed provider send stays succeeded when local mirror write fails" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-mirror-fails-after-send",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "visible"
               })

      test_pid = self()

      log =
        capture_log(fn ->
          assert {:ok, succeeded} =
                   SignalsGateway.dispatch_outbox(
                     agent.uid,
                     "bot",
                     "post-mirror-fails-after-send",
                     %{
                       capabilities: [:post_entry],
                       send: fn _outbox ->
                         {:ok,
                          %{
                            provider_entry_id: "mirror-fails-after-send",
                            raw_payload: %{"pid" => test_pid}
                          }}
                       end
                     },
                     now: @base_time
                   )

          send(test_pid, {:succeeded_outbox, succeeded})
        end)

      assert_receive {:succeeded_outbox, succeeded}
      assert succeeded.status == :succeeded
      assert succeeded.provider_entry_id == "mirror-fails-after-send"

      assert Repo.get_by!(OutboxEntry,
               agent_uid: agent.uid,
               binding_name: "bot",
               outbound_key: "post-mirror-fails-after-send"
             ).status == :succeeded

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "mirror-fails-after-send"
             )

      assert log =~ "signals_gateway outbox mirror failed after provider send"
    end

    test "outbox reply edit delete reaction divider and card mirror only after success" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, reply} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reply-ok",
                   operation: :reply,
                   signal_channel_id: "lark:chat:group-a",
                   source_provider_entry_id: "msg-1",
                   fallback_visible_text: "reply visible"
                 },
                 [:reply_entry],
                 %{provider_entry_id: "reply-msg"}
               )

      assert reply.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).text == "reply visible"

      assert {:ok, edited} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "edit-ok",
                   operation: :edit,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg",
                   fallback_visible_text: "edited visible"
                 },
                 [:edit_entry],
                 %{}
               )

      assert edited.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).text == "edited visible"

      assert {:ok, reaction_add} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reaction-add-ok",
                   operation: :reaction_add,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg",
                   payload: %{reaction_key: "thumbsup", actor_key: "agent"}
                 },
                 [:add_reaction],
                 %{}
               )

      assert reaction_add.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).reactions == %{"thumbsup" => ["agent"]}

      assert {:ok, reaction_remove} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "reaction-remove-ok",
                   operation: :reaction_remove,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg",
                   payload: %{reaction_key: "thumbsup", actor_key: "agent"}
                 },
                 [:remove_reaction],
                 %{}
               )

      assert reaction_remove.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             ).reactions == %{}

      assert {:ok, divider} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "divider-ok",
                   operation: :divider,
                   signal_channel_id: "lark:chat:group-a",
                   fallback_visible_text: "---"
                 },
                 [:post_entry, :divider],
                 %{provider_entry_id: "divider-msg"}
               )

      assert divider.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "divider-msg"
             ).text == "---"

      assert {:ok, card} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "card-ok",
                   operation: :card,
                   signal_channel_id: "lark:chat:group-a",
                   fallback_visible_text: "card fallback"
                 },
                 [:post_entry, :card],
                 %{provider_entry_id: "card-msg"}
               )

      assert card.status == :succeeded

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "card-msg"
             ).text == "card fallback"

      assert {:ok, deleted} =
               commit_and_dispatch(
                 agent.uid,
                 "bot",
                 %{
                   outbound_key: "delete-ok",
                   operation: :delete,
                   signal_channel_id: "lark:chat:group-a",
                   target_provider_entry_id: "reply-msg"
                 },
                 [:delete_entry],
                 %{}
               )

      assert deleted.status == :succeeded

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "reply-msg"
             )
    end

    test "in-flight outbox recovers by reconciliation or marks unknown when unprovable" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, unknown_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-unknown",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "maybe sent",
                 provider_entry_id: "maybe-provider-id"
               })

      {:ok, _sending} =
        unknown_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-unknown",
                 %{capabilities: [:post_entry]},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert unknown.status == :unknown_after_send

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "maybe-provider-id"
             )

      assert {:ok, reconcile_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-reconcile",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "confirmed",
                 provider_entry_id: "confirmed-provider-id"
               })

      {:ok, _sending} =
        reconcile_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, recovered} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-reconcile",
                 %{
                   capabilities: [:post_entry, :outbound_reconciliation],
                   reconcile: fn _outbox ->
                     {:ok, %{provider_entry_id: "confirmed-provider-id"}}
                   end
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert recovered.status == :succeeded

      assert Repo.get_by!(
               SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "confirmed-provider-id"
             ).text == "confirmed"
    end

    test "invalid reconcile result marks in-flight outbox unknown without crashing" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-invalid-reconcile",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "maybe sent",
                 provider_entry_id: "maybe-sent-provider-id"
               })

      {:ok, _sending} =
        seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-invalid-reconcile",
                 %{
                   capabilities: [:post_entry, :outbound_reconciliation],
                   reconcile: fn _outbox -> :ok end
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert unknown.status == :unknown_after_send
      assert unknown.last_error["reason"] == "reconciliation adapter error"
      assert unknown.last_error["error"]["items"] |> hd() == "invalid_adapter_result"
    end

    test "due outbox dispatch picks up stale in-flight sends for reconciliation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, stale_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "stale-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "confirmed by reconcile",
                 provider_entry_id: "stale-provider-id"
               })

      due_now = DateTime.add(@base_time, 61, :second)

      {:ok, _sending} =
        stale_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, fresh_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "fresh-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "still in flight",
                 provider_entry_id: "fresh-provider-id"
               })

      {:ok, _fresh} =
        fresh_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: DateTime.add(due_now, -30, :second)
        })
        |> Repo.update()

      assert [%OutboxEntry{outbound_key: "stale-sending"}] =
               SignalsGateway.list_due_outbox(due_now, 10)

      assert [{:ok, %OutboxEntry{status: :succeeded}}] =
               SignalsGateway.dispatch_due_outbox(
                 fn %OutboxEntry{binding_name: "bot"} ->
                   {:ok,
                    %{
                      capabilities: [:post_entry, :outbound_reconciliation],
                      reconcile: fn _outbox ->
                        {:ok, %{provider_entry_id: "stale-provider-id"}}
                      end
                    }}
                 end,
                 now: due_now,
                 limit: 10
               )

      assert Repo.get_by!(
               SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "stale-provider-id"
             ).text == "confirmed by reconcile"
    end

    test "due outbox dispatch honors retry backoff through a code resolver" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-retry",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "retry me"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:error, :rate_limited} end},
                 now: @base_time
               )

      assert failed.status == :failed

      assert {:error, :outbox_not_due} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:ok, %{}} end},
                 now: DateTime.add(@base_time, 1, :second)
               )

      due_now = DateTime.add(failed.next_attempt_at, 1, :microsecond)

      assert [%OutboxEntry{outbound_key: "post-retry"}] =
               SignalsGateway.list_due_outbox(due_now, 10)

      assert [{:ok, %OutboxEntry{status: :succeeded}}] =
               SignalsGateway.dispatch_due_outbox(
                 fn %OutboxEntry{binding_name: "bot"} ->
                   {:ok,
                    %{
                      capabilities: [:post_entry],
                      send: fn _outbox -> {:ok, %{provider_entry_id: "retry-provider-id"}} end
                    }}
                 end,
                 now: due_now,
                 limit: 10
               )
    end

    test "TTL cleanup is an Oban default-queue worker over SignalsGateway TTL tables" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, _} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "delete-expiring"}),
                 now: @base_time
               )

      assert %Oban.Job{queue: "default"} =
               Ankole.SignalsGateway.Jobs.CleanupExpiredState.new(%{})
               |> Ecto.Changeset.apply_changes()

      counts =
        SignalsGateway.cleanup_expired_state(DateTime.add(@base_time, 2 * 24 * 60 * 60, :second))

      assert counts.tombstones == 1
      assert Repo.aggregate(InputTombstone, :count) == 0
    end
  end

  describe "negative storage assertions" do
    test "gateway storage does not contain resolver, observation, lifecycle, or second outbox abstractions" do
      columns =
        SQL.query!(
          Repo,
          """
          SELECT table_name, column_name
          FROM information_schema.columns
          WHERE table_schema = 'public'
          """,
          []
        ).rows

      refute Enum.any?(columns, fn [_table, column] -> column == "resolver_key" end)
      refute Enum.any?(columns, fn [_table, column] -> column == "observed_only" end)

      refute Enum.any?(columns, fn [table, column] ->
               table == "signal_entries" and column == "provider_thread_id"
             end)

      refute Enum.any?(columns, fn [table, column] ->
               table == "actor_inputs" and column == "canceled_at"
             end)

      refute Enum.any?(columns, fn [table, column] ->
               table == "actor_input_consumptions" and column == "payload"
             end)

      tables =
        SQL.query!(
          Repo,
          """
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = 'public'
          """,
          []
        ).rows
        |> List.flatten()

      refute Enum.any?(tables, &String.contains?(&1, "entry_lifecycle"))
      refute Enum.any?(tables, &String.contains?(&1, "binding_channel"))
      refute "signal_gateway_processed_ingress_events" in tables

      assert "signal_gateway_outbox" in tables
      refute "actor_outbox" in tables
    end
  end

  defp binding_fixture(agent_uid, name, policy, opts \\ []) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: Keyword.get(opts, :adapter, "lark"),
        config_ref: "app-config://#{name}",
        filters: Keyword.get(opts, :filters, %{}),
        unaddressed_group_message_policy: policy,
        unavailable_reason: Keyword.get(opts, :unavailable_reason)
      })

    binding
  end

  defp group_entry(overrides \\ %{}) do
    Map.merge(
      %{
        ingress_event_id: "evt-1",
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "hello",
        author: %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
        provider_time: @base_time
      },
      overrides
    )
  end

  defp lifecycle_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "delete-1",
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-1",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  defp webhook_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "hook-event-1",
        signal_channel_id: "webhook:incident-1",
        provider_entry_id: "hook-1",
        channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"},
        text: "incident opened",
        actor_input_type: "webhook.received",
        provider_time: @base_time
      },
      overrides
    )
  end

  defp commit_and_dispatch(agent_uid, binding_name, attrs, capabilities, adapter_result) do
    attrs =
      attrs
      |> Map.put(:agent_uid, agent_uid)
      |> Map.put(:binding_name, binding_name)

    with {:ok, _outbox} <- SignalsGateway.commit_outbox(attrs) do
      SignalsGateway.dispatch_outbox(
        agent_uid,
        binding_name,
        attrs.outbound_key,
        %{capabilities: capabilities, send: fn _outbox -> {:ok, adapter_result} end},
        now: @base_time
      )
    end
  end
end
