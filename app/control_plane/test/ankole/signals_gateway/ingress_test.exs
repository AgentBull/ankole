defmodule Ankole.SignalsGatewayIngressTest do
  use Ankole.DataCase, async: false

  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorInputTypes
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import Ecto.Query

  @base_time ~U[2026-06-23 08:00:00.000000Z]

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

    test "may_intervene batch removal drops only the recalled source entry" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: first}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   ingress_event_id: "evt-ambient-remove-first",
                   provider_entry_id: "msg-ambient-remove-first",
                   text: "first"
                 }),
                 now: @base_time
               )

      second_at = DateTime.add(@base_time, 250, :millisecond)

      assert {:ok, %{inbound_batch: second}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   ingress_event_id: "evt-ambient-remove-second",
                   provider_entry_id: "msg-ambient-remove-second",
                   text: "second"
                 }),
                 now: second_at
               )

      assert first.id == second.id

      assert {:ok, %{updated_inbound_batches: 1, lifecycle_inputs: []}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "lark-main",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-ambient-remove-first",
                   provider_entry_id: "msg-ambient-remove-first"
                 }),
                 now: DateTime.add(@base_time, 500, :millisecond)
               )

      updated = Repo.get!(InboundBatch, first.id)

      assert [%{"provider_entry_id" => "msg-ambient-remove-second", "text" => "second"}] =
               updated.entries

      due_at = updated.available_at

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(now: due_at)

      assert input.type == "im.message.may_intervene"

      assert [%{"provider_entry_id" => "msg-ambient-remove-second", "text" => "second"}] =
               get_in(input.payload, ["data", "observed_messages"])

      assert %InboundBatch{
               batch_state: "finalized",
               entries: [%{"provider_entry_id" => "msg-ambient-remove-second"}],
               outcome: "ambient"
             } = Repo.get!(InboundBatch, first.id)
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
end
