defmodule Ankole.SignalsGatewayIngressTest do
  use Ankole.DataCase, async: false

  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEventTypes
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.Entry

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import Ecto.Query

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "binding policy and actor handoff" do
    test "ignore skips unaddressed group entries without mirroring or waking" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{status: :ignored}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(InboundBatch, :count) == 1
    end

    test "record_only mirrors unaddressed group entries without actor event" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      assert {:ok, %{status: :recorded, signal_entry: entry}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert entry.signal_channel_id == "lark:chat:group-a"
      assert entry.source_entry_id == "msg-1"
      assert entry.search_text == "hello"
      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(InboundBatch, :count) == 1
    end

    test "may_intervene mirrors and finalizes a delayed ambient observation input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      due_at = DateTime.add(@base_time, 15_000, :millisecond)

      assert batch.available_at == due_at
      assert Repo.aggregate(ActorEvent, :count) == 0

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert input.type == "im.message.may_intervene"
      assert input.available_at == due_at

      assert [%{"speaker" => "Alice", "sent_at" => sent_at, "text" => "hello"}] =
               input.payload["data"]["observed_messages"]

      assert sent_at == DateTime.to_iso8601(@base_time)
      assert input.sender_key == nil
    end

    test "inbound batch deadline finalizes exact batch revision" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: batch}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert Repo.aggregate(ActorEvent, :count) == 0

      assert {:ok, %{status: :accepted, actor_event: input}} =
               SignalsGateway.finalize_inbound_batch_by_id(
                 batch.id,
                 batch.batch_revision,
                 now: batch.available_at
               )

      assert input.type == "im.message.may_intervene"
      assert Repo.get!(InboundBatch, batch.id).batch_state == "finalized"
    end

    test "may_intervene entries in the same room and thread finalize as one ambient input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: first}} =
               Ingress.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-first",
                   source_entry_id: "msg-ambient-first",
                   text: "first"
                 }),
                 now: @base_time
               )

      second_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{inbound_batch: second}} =
               Ingress.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-second",
                   source_entry_id: "msg-ambient-second",
                   text: "second"
                 }),
                 now: second_at
               )

      due_at = DateTime.add(second_at, 15_000, :millisecond)
      merged = Repo.get!(InboundBatch, first.id)

      assert first.id == second.id
      assert Repo.aggregate(ActorEvent, :count) == 0
      assert merged.available_at == due_at

      assert [
               %{"source_entry_id" => "msg-ambient-first", "text" => "first"},
               %{"source_entry_id" => "msg-ambient-second", "text" => "second"}
             ] = merged.entries

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert [
               %{"speaker" => "Alice", "text" => "first"},
               %{"speaker" => "Alice", "text" => "second"}
             ] = input.payload["data"]["observed_messages"]

      assert %ActorEvent{id: id} =
               Actors.next_ready_event(
                 agent.uid,
                 SignalsGateway.signal_session_id("lark:chat:group-a"),
                 due_at
               )

      assert id == input.id
    end

    test "ambient observation recall only uses provider-visible signal mirrors" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      session_id = SignalsGateway.signal_session_id("lark:chat:group-a")
      assert {:ok, conversation} = Conversations.ensure_conversation(agent.uid, session_id)

      Repo.insert!(%Message{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        type: "message",
        role: "assistant",
        status: "complete",
        content: [%{"text" => "internal assistant row"}],
        metadata: %{
          "signal_channel_id" => "lark:chat:group-a",
          "source_entry_id" => "internal-row",
          "provider_thread_id" => "thread-1"
        },
        inserted_at: @base_time,
        updated_at: @base_time
      })

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      observed = input.payload["data"]["observed_messages"]

      assert [%{"source_entry_id" => "msg-1", "text" => "hello"}] = observed
      refute Enum.any?(observed, &(&1["source"] == "ai_gateway_messages"))
      refute Enum.any?(observed, &(&1["text"] == "internal assistant row"))
    end

    test "may_intervene payload includes pre-batch transcript and unreplied ambient context" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      insert_signal_entry!(
        "msg-history-old",
        "old transcript context",
        DateTime.add(@base_time, -12, :second)
      )

      insert_signal_entry!(
        "msg-history-agent",
        "previous agent answer",
        DateTime.add(@base_time, -10, :second),
        %{agent_uid: agent.uid, display_name: "Research Agent"}
      )

      insert_signal_entry!(
        "msg-backlog-1",
        "this strategy might be worth a backtest",
        DateTime.add(@base_time, -8, :second),
        %{principal_uid: "bob", id: "ou_bob", display_name: "Bob"}
      )

      insert_signal_entry!(
        "msg-backlog-2",
        "which benchmark should we use?",
        DateTime.add(@base_time, -7, :second),
        %{principal_uid: "carol", id: "ou_carol", display_name: "Carol"}
      )

      insert_signal_entry!(
        "msg-other-thread",
        "different thread",
        DateTime.add(@base_time, -6, :second),
        %{principal_uid: "dave", id: "ou_dave", display_name: "Dave"},
        "thread-2"
      )

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      assert get_in(input.payload, ["data", "entry", "text"]) ==
               "[#{DateTime.to_iso8601(@base_time)} Alice] hello"

      assert [
               %{"role" => "ambient_human", "text" => "old transcript context"},
               %{"role" => "agent", "text" => "previous agent answer"},
               %{"role" => "ambient_human", "text" => "this strategy might be worth a backtest"},
               %{"role" => "ambient_human", "text" => "which benchmark should we use?"}
             ] = get_in(input.payload, ["data", "recent_history"])

      assert [
               %{"text" => "this strategy might be worth a backtest"},
               %{"text" => "which benchmark should we use?"}
             ] = get_in(input.payload, ["data", "earlier_observed_messages"])

      refute input.payload
             |> get_in(["data", "recent_history"])
             |> Enum.any?(&(&1["text"] == "different thread"))
    end

    test "upgraded ignore batch mirroring does not overwrite newer provider state" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      bob = %{principal_uid: "bob", id: "provider-bob", display_name: "Bob"}

      assert {:ok, %{status: :ignored, inbound_batch: neutral_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-stale-batch-old",
                   source_entry_id: "msg-stale-batch-old",
                   text: "old batch text",
                   author: bob,
                   provider_time: @base_time
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(Entry, :count) == 0

      newer_time = DateTime.add(@base_time, 5, :second)

      assert {:ok, newer_fact} =
               IngressFact.entry(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 adapter: "lark",
                 source_event_id: "evt-stale-batch-newer",
                 signal_channel_id: "lark:chat:group-a",
                 source_entry_id: "msg-stale-batch-old",
                 provider_thread_id: "thread-1",
                 channel_kind: :im_group,
                 reply_mode: :entry,
                 channel_name: "Ops",
                 text: "new provider text",
                 formatted_content: %{},
                 attachments: [],
                 links: [],
                 author: bob,
                 mentions: [],
                 metadata: %{},
                 raw_payload: %{},
                 provider_time: newer_time
               })

      assert {:ok, _entry} =
               Repo.transact(fn repo ->
                 Projection.mirror_receive_entry(repo, newer_fact, newer_time)
               end)

      mention_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-stale-batch-trigger",
                   source_entry_id: "msg-stale-batch-trigger",
                   explicit: true,
                   text: "@bot help",
                   author: bob,
                   provider_time: mention_at
                 }),
                 now: mention_at
               )

      assert addressed_batch.id == neutral_batch.id
      assert addressed_batch.mode == "addressed"

      assert {:ok, [%{status: :accepted}]} =
               finalize_due_inbound_batch_events(now: addressed_batch.available_at)

      assert %Entry{text: "new provider text", provider_time: ^newer_time} =
               Repo.get_by!(Entry,
                 signal_channel_id: "lark:chat:group-a",
                 source_entry_id: "msg-stale-batch-old"
               )
    end

    test "may_intervene batch removal drops only the recalled source entry" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: first}} =
               Ingress.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-remove-first",
                   source_entry_id: "msg-ambient-remove-first",
                   text: "first"
                 }),
                 now: @base_time
               )

      second_at = DateTime.add(@base_time, 250, :millisecond)

      assert {:ok, %{inbound_batch: second}} =
               Ingress.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-remove-second",
                   source_entry_id: "msg-ambient-remove-second",
                   text: "second"
                 }),
                 now: second_at
               )

      assert first.id == second.id

      assert {:ok, %{updated_inbound_batches: 1, lifecycle_events: []}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "lark-main",
                 lifecycle_entry(%{
                   source_event_id: "recall-ambient-remove-first",
                   source_entry_id: "msg-ambient-remove-first"
                 }),
                 now: DateTime.add(@base_time, 500, :millisecond)
               )

      updated = Repo.get!(InboundBatch, first.id)

      assert [%{"source_entry_id" => "msg-ambient-remove-second", "text" => "second"}] =
               updated.entries

      due_at = updated.available_at

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert input.type == "im.message.may_intervene"

      assert [%{"source_entry_id" => "msg-ambient-remove-second", "text" => "second"}] =
               get_in(input.payload, ["data", "observed_messages"])

      assert %InboundBatch{
               batch_state: "finalized",
               entries: [%{"source_entry_id" => "msg-ambient-remove-second"}],
               outcome: "ambient"
             } = Repo.get!(InboundBatch, first.id)
    end

    test "removing the addressed trigger downgrades a pending ignore batch to no actor event" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      bob = %{principal_uid: "bob", id: "provider-bob", display_name: "Bob"}

      assert {:ok, %{status: :ignored, inbound_batch: neutral_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-neutral-before-recall",
                   source_entry_id: "msg-neutral-before-recall",
                   author: bob,
                   text: "context before mention"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-recalled-mention",
                   source_entry_id: "msg-recalled-mention",
                   author: bob,
                   text: "@Agent please ignore this after recall",
                   mentions: [%{kind: :agent, structured: true, agent_uid: agent.uid}]
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert addressed_batch.id == neutral_batch.id
      assert addressed_batch.mode == "addressed"

      assert {:ok, %{updated_inbound_batches: 1, lifecycle_events: []}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "recall-addressed-trigger",
                   source_entry_id: "msg-recalled-mention"
                 }),
                 now: DateTime.add(@base_time, 200, :millisecond)
               )

      updated = Repo.get!(InboundBatch, neutral_batch.id)

      assert updated.mode == "neutral"
      assert is_nil(updated.requester_sender_key)

      assert [%{"source_entry_id" => "msg-neutral-before-recall"}] = updated.entries

      assert {:ok, [%{status: :ignored, inbound_batch: finalized}]} =
               finalize_due_inbound_batch_events(now: updated.available_at)

      assert finalized.outcome == "no_actor_event"
      assert Repo.aggregate(ActorEvent, :count) == 0
    end

    test "DM and structured mentions are explicit even when group policy is ignore" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{inbound_batch: dm_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-dm",
                   source_entry_id: "dm-msg-1",
                   signal_channel_id: "lark:dm:alice-agent",
                   channel: %{kind: :im_dm, reply_mode: :entry},
                   text: "dm"
                 }),
                 now: @base_time
               )

      assert {:ok, [%{actor_event: dm_input}]} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 600, :millisecond))

      assert dm_input.type == "im.message.addressed"
      assert dm_batch.mode == "addressed"

      assert {:ok, %{inbound_batch: mention_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-mention",
                   source_entry_id: "msg-mention",
                   text: "@Agent do this",
                   mentions: [%{kind: :agent, structured: true, agent_uid: agent.uid}]
                 }),
                 now: @base_time
               )

      assert {:ok, [%{actor_event: mention_input}]} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 600, :millisecond))

      assert mention_input.type == "im.message.addressed"
      assert mention_batch.mode == "addressed"
    end

    test "unmentioned group replies do not become addressed input without a real runtime match" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{status: :ignored, inbound_batch: batch}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert {:ok, [%{status: :ignored, inbound_batch: finalized}]} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 600, :millisecond))

      assert finalized.id == batch.id
      assert batch.mode == "neutral"
      assert Repo.aggregate(ActorEvent, :count) == 0
    end

    test "non-IM entries need code-defined actor event type instead of addressed IM fallback" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:error, :missing_actor_event_type} =
               Ingress.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{actor_event_type: nil}),
                 now: @base_time
               )

      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "unavailable bindings do not accept ingress even when enabled" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore, unavailable_reason: "adapter missing")

      assert {:error, {:binding_unavailable, "adapter missing"}} =
               Ingress.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)
    end

    test "CEL binding filters can admit or filter ingress before mirror and actor event writes" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "bot", :ignore,
        filters: %{"cel" => "signal.channel.id == 'lark:chat:allowed'"}
      )

      assert {:ok, %{status: :filtered}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0

      %{actor_event: input} =
        emit_addressed_actor_event(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            source_event_id: "evt-allowed",
            signal_channel_id: "lark:chat:allowed",
            source_entry_id: "msg-allowed"
          })
        )

      assert input.signal_channel_id == "lark:chat:allowed"
      assert Repo.aggregate(Entry, :count) == 1
      assert Repo.aggregate(ActorEvent, :count) == 1
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
               Ingress.emit_entry(
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

      %{actor_event: input} =
        emit_addressed_actor_event(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            sender_key: "lark:user:alice",
            source_event_id: "evt-cel-functions",
            signal_channel_id: "lark:chat:allowed",
            source_entry_id: "msg-cel-functions"
          })
        )

      assert input.sender_key == "lark:user:alice"
    end

    test "CEL binding filters keep booleans and null as JSON values" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "bot", :ignore,
        filters: %{
          "cel" =>
            "signal.entry.explicit == true && signal.entry.mirror_only == false && signal.entry.thread_id == null"
        }
      )

      %{actor_event: input} =
        emit_addressed_actor_event(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            provider_thread_id: nil,
            source_event_id: "evt-cel-json-values",
            source_entry_id: "msg-cel-json-values"
          })
        )

      assert input.source_entry_id == "msg-cel-json-values"
    end

    test "invalid CEL filters fail before durable writes" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "runtime-error", :ignore,
        filters: %{"cel" => "signal.entry.missing == true"}
      )

      assert {:error, {:invalid_binding_filter, reason}} =
               Ingress.emit_entry(
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

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0
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

      %{actor_event: input} =
        emit_addressed_actor_event(
          agent.uid,
          "bot",
          group_entry(%{
            source_event_id: "evt-known-author",
            source_entry_id: "msg-known-author",
            explicit: true,
            author: %{platform_subject: "ou_alice", display_name: "Alice"}
          })
        )

      assert input.sender_key == "alice"

      assert %Entry{author: %{"principal_uid" => "alice", "platform_subject" => "ou_alice"}} =
               Repo.get_by!(Entry,
                 signal_channel_id: "lark:chat:group-a",
                 source_entry_id: "msg-known-author"
               )
    end
  end

  describe "mirror identity and route-scoped delivery" do
    test "same physical channel and entry share one mirror row while actor event remains per binding" do
      %{principal: agent_a} = agent_fixture()
      %{principal: agent_b} = agent_fixture()
      binding_fixture(agent_a.uid, "bot-a", :ignore)
      binding_fixture(agent_b.uid, "bot-b", :ignore)

      explicit = group_entry(%{explicit: true})

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent_a.uid, "bot-a", explicit, now: @base_time)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(
                 agent_b.uid,
                 "bot-b",
                 %{explicit | source_event_id: "evt-1-b"},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert Repo.aggregate(Entry, :count) == 1

      assert {:ok, [%{actor_event: _input_a}, %{actor_event: _input_b}]} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 2, :second))

      assert Repo.aggregate(ActorEvent, :count) == 2

      assert Repo.aggregate(
               from(input in ActorEvent, where: input.agent_uid == ^agent_a.uid),
               :count
             ) == 1

      assert Repo.aggregate(
               from(input in ActorEvent, where: input.agent_uid == ^agent_b.uid),
               :count
             ) == 1
    end

    test "different provider entry ids are not guessed as duplicates" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-2",
                   source_entry_id: "provider-specific-msg-2"
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(Entry, :count) == 2
    end
  end

  describe "commands and inbound IM batching" do
    test "recognized commands stay typed command events and steer maps through code" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_event: compress_event}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, text: "/compress release notes"}),
                 now: @base_time
               )

      assert compress_event.type == "command.compress"
      assert compress_event.payload["type"] == "command.compress"
      assert compress_event.payload["data"]["command"]["argsText"] == "release notes"
      assert ActorEventTypes.command_runtime_policy("command.stop") == :control_now
      assert ActorEventTypes.command_runtime_policy("command.retry") == :control_now
      assert ActorEventTypes.command_runtime_policy("command.new") == :control_now
      assert ActorEventTypes.command_runtime_policy("command.compress") == :control_now
      assert ActorEventTypes.command_runtime_policy("command.steer") == :checkpoint_nudge

      assert {:ok, %{actor_event: input}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-steer-1",
                   source_entry_id: "msg-steer-1",
                   text: "/steer be concise"
                 }),
                 now: @base_time
               )

      assert input.type == "command.steer"
      assert input.available_at == @base_time
      assert input.payload["type"] == "command.steer"
      assert input.payload["data"]["command"]["argsText"] == "be concise"
      refute Map.has_key?(input.payload["data"]["command"], "status")
    end

    test "unsupported commands and full-width slash remain normal addressed text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_event: undo_input} =
        emit_addressed_actor_event(
          agent.uid,
          "bot",
          group_entry(%{explicit: true, text: "/undo"})
        )

      assert undo_input.type == "im.message.addressed"

      %{actor_event: full_width_input} =
        emit_addressed_actor_event(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            source_event_id: "evt-full-width",
            source_entry_id: "msg-full-width",
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

    test "addressed IM entries close as sender-scoped actor event batches" do
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
                 Ingress.emit_entry(
                   agent.uid,
                   "bot",
                   group_entry(%{
                     explicit: true,
                     source_event_id: event_id,
                     source_entry_id: entry_id,
                     author: author,
                     text: text
                   }),
                   now: DateTime.add(@base_time, offset, :millisecond)
                 )
      end

      assert Repo.aggregate(ActorEvent, :count) == 1

      rows =
        ActorEvent
        |> order_by([input], asc: input.inserted_at)
        |> Repo.all()

      assert Enum.map(rows, & &1.sender_key) == ["alice"]

      [alice_input] = rows
      assert alice_input.source_entry_id == "msg-a2"
      assert get_in(alice_input.payload, ["data", "entry", "text"]) == "first\nsecond"

      assert [
               %{"source_entry_id" => "msg-a1", "text" => "first"},
               %{"source_entry_id" => "msg-a2", "text" => "second"}
             ] = get_in(alice_input.payload, ["data", "entries"])

      assert [%InboundBatch{mode: "addressed", requester_sender_key: "bob"} = bob_batch] =
               InboundBatch
               |> where([batch], batch.batch_state == "open")
               |> Repo.all()

      due_at = DateTime.add(@base_time, 800, :millisecond)

      assert {:ok, [%{actor_event: bob_input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert bob_input.source_entry_id == "msg-b1"
      assert bob_batch.id == Repo.get!(InboundBatch, bob_batch.id).id
    end

    test "duplicate provider deliveries do not duplicate addressed batch text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      first =
        group_entry(%{
          explicit: true,
          source_event_id: "evt-duplicate-delivery-1",
          source_entry_id: "msg-duplicate-delivery",
          text: "@Agent please answer once"
        })

      assert {:ok, %{status: :accepted, inbound_batch: first_batch}} =
               Ingress.emit_entry(agent.uid, "bot", first, now: @base_time)

      duplicate_at = DateTime.add(@base_time, 100, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: duplicate_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 %{first | source_event_id: "evt-duplicate-delivery-2"},
                 now: duplicate_at
               )

      assert duplicate_batch.id == first_batch.id
      assert duplicate_batch.available_at == first_batch.available_at
      assert Repo.aggregate(Entry, :count) == 1

      assert [
               %{
                 "source_entry_id" => "msg-duplicate-delivery",
                 "text" => "@Agent please answer once"
               }
             ] =
               Repo.get!(InboundBatch, first_batch.id).entries

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(now: first_batch.available_at)

      assert input.source_entry_id == "msg-duplicate-delivery"
      assert get_in(input.payload, ["data", "entry", "text"]) == "@Agent please answer once"

      assert [%{"source_entry_id" => "msg-duplicate-delivery"}] =
               get_in(input.payload, ["data", "entries"])
    end

    test "newer provider state replaces a pending duplicate batch entry" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      first =
        group_entry(%{
          explicit: true,
          source_event_id: "evt-edited-delivery-1",
          source_entry_id: "msg-edited-delivery",
          text: "@Agent old text",
          provider_time: @base_time
        })

      assert {:ok, %{status: :accepted, inbound_batch: first_batch}} =
               Ingress.emit_entry(agent.uid, "bot", first, now: @base_time)

      edited_at = DateTime.add(@base_time, 100, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: edited_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 %{
                   first
                   | source_event_id: "evt-edited-delivery-2",
                     text: "@Agent corrected text",
                     provider_time: edited_at
                 },
                 now: edited_at
               )

      assert edited_batch.id == first_batch.id
      assert edited_batch.available_at == DateTime.add(edited_at, 600, :millisecond)
      assert Repo.aggregate(Entry, :count) == 1

      assert [
               %{
                 "source_entry_id" => "msg-edited-delivery",
                 "text" => "@Agent corrected text"
               }
             ] =
               Repo.get!(InboundBatch, first_batch.id).entries

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(now: edited_batch.available_at)

      assert input.source_entry_id == "msg-edited-delivery"
      assert get_in(input.payload, ["data", "entry", "text"]) == "@Agent corrected text"

      assert %Entry{text: "@Agent corrected text", provider_time: ^edited_at} =
               Repo.get_by!(Entry,
                 signal_channel_id: "lark:chat:group-a",
                 source_entry_id: "msg-edited-delivery"
               )
    end

    test "one poisoned inbound batch does not block later due batches" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted, inbound_batch: poisoned_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-poisoned-batch",
                   source_entry_id: "msg-poisoned-batch",
                   provider_thread_id: "thread-poisoned",
                   text: "poisoned"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted, inbound_batch: good_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-good-batch",
                   source_entry_id: "msg-good-batch",
                   provider_thread_id: "thread-good",
                   text: "good"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      InboundBatch
      |> where([batch], batch.id == ^poisoned_batch.id)
      |> Repo.update_all(set: [binding_name: ""])

      due_at = DateTime.add(@base_time, 800, :millisecond)

      assert {:ok, results} = finalize_due_inbound_batch_events(now: due_at)

      assert Enum.any?(results, &match?(%{status: :finalize_failed}, &1))
      assert %{actor_event: good_input} = Enum.find(results, &match?(%{actor_event: _}, &1))
      assert good_input.source_entry_id == "msg-good-batch"
      assert Repo.get!(InboundBatch, good_batch.id).batch_state == "finalized"
    end

    test "neutral batch upgrades only the final same-sender run when bot is mentioned" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      alice = %{principal_uid: "alice", id: "provider-alice", display_name: "Alice"}
      bob = %{principal_uid: "bob", id: "provider-bob", display_name: "Bob"}

      assert {:ok, %{status: :ignored}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-alice-neutral",
                   source_entry_id: "msg-alice-neutral",
                   author: alice,
                   text: "alice aside"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :ignored}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-bob-neutral",
                   source_entry_id: "msg-bob-neutral",
                   author: bob,
                   text: "bob context"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-bob-mention",
                   source_entry_id: "msg-bob-mention",
                   author: bob,
                   text: "@Agent help",
                   mentions: [%{kind: :agent, structured: true, agent_uid: agent.uid}]
                 }),
                 now: DateTime.add(@base_time, 200, :millisecond)
               )

      assert addressed_batch.mode == "addressed"
      assert addressed_batch.requester_sender_key == "bob"

      due_at = DateTime.add(@base_time, 800, :millisecond)

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert get_in(input.payload, ["data", "entry", "text"]) == "bob context\n@Agent help"

      assert [
               %{"source_entry_id" => "msg-bob-neutral"},
               %{"source_entry_id" => "msg-bob-mention"}
             ] = get_in(input.payload, ["data", "entries"])

      refute Repo.get_by(Entry,
               signal_channel_id: "lark:chat:group-a",
               source_entry_id: "msg-alice-neutral"
             )
    end

    test "inline finalized addressed batch starts a preview handler" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      alice = %{principal_uid: "alice", id: "provider-alice", display_name: "Alice"}
      bob = %{principal_uid: "bob", id: "provider-bob", display_name: "Bob"}

      assert {:ok, %{status: :accepted, inbound_batch: first_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-inline-preview-alice",
                   source_entry_id: "msg-inline-preview-alice",
                   author: alice,
                   text: "@Agent first"
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(ActorEvent, :count) == 0

      assert {:ok,
              %{
                status: :accepted,
                inbound_batch: second_batch,
                finalized_actor_events: [first_event]
              }} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-inline-preview-bob",
                   source_entry_id: "msg-inline-preview-bob",
                   author: bob,
                   text: "@Agent second"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert second_batch.id != first_batch.id
      assert first_event.type == "im.message.addressed"
      assert get_in(first_event.payload, ["data", "entry", "text"]) == "@Agent first"
      assert is_pid(wait_for_preview_handler(first_event.id))
    end

    test "addressed text followed by attachment waits on the attachment window and merges" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{inbound_batch: first_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-text",
                   source_entry_id: "msg-text",
                   text: "look at this"
                 }),
                 now: @base_time
               )

      attachment_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{inbound_batch: updated_batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-image",
                   source_entry_id: "msg-image",
                   text: "image",
                   attachments: [
                     %{
                       provider_ref: "lark:image:image-1",
                       source_message_id: "msg-image",
                       name: "chart.png"
                     },
                     %{
                       provider_ref: "lark:image:image-1",
                       source_message_id: "msg-image",
                       name: "chart.png"
                     }
                   ]
                 }),
                 now: attachment_at
               )

      assert first_batch.id == updated_batch.id

      assert Repo.get!(InboundBatch, first_batch.id).available_at ==
               DateTime.add(attachment_at, 1_200, :millisecond)

      assert {:ok, []} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 1_100, :millisecond)
               )

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(attachment_at, 1_200, :millisecond)
               )

      assert get_in(input.payload, ["data", "entry", "text"]) == "look at this\nimage"

      assert [
               %{
                 "provider_ref" => "lark:image:image-1",
                 "source_message_id" => "msg-image",
                 "name" => "chart.png"
               }
             ] =
               get_in(input.payload, ["data", "entry", "attachments"])
    end

    test "single addressed message over the normal text budget is not split" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      long_text = String.duplicate("x", 4_500)

      assert {:ok, %{inbound_batch: batch}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   text: long_text
                 }),
                 now: @base_time
               )

      assert [%{"text" => ^long_text}] = batch.entries

      assert {:ok, [%{actor_event: input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 2_000, :millisecond)
               )

      assert get_in(input.payload, ["data", "entry", "text"]) == long_text
      assert [_one_entry] = get_in(input.payload, ["data", "entries"])
    end
  end

  defp wait_for_preview_handler(actor_event_id, attempts_left \\ 20)

  defp wait_for_preview_handler(actor_event_id, attempts_left) when attempts_left > 0 do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] ->
        pid

      [] ->
        receive do
        after
          50 -> wait_for_preview_handler(actor_event_id, attempts_left - 1)
        end
    end
  end

  defp wait_for_preview_handler(actor_event_id, 0) do
    flunk("preview handler for actor_event_id=#{actor_event_id} was not started")
  end

  defp insert_signal_entry!(
         source_entry_id,
         text,
         provider_time,
         author \\ %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
         provider_thread_id \\ "thread-1"
       ) do
    Repo.insert!(%Entry{
      signal_channel_id: "lark:chat:group-a",
      source_entry_id: source_entry_id,
      text: text,
      formatted_content: %{},
      attachments: [],
      links: [],
      author: author,
      mentions: [],
      metadata: %{"provider_thread_id" => provider_thread_id},
      raw_payload: %{},
      provider_time: provider_time,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "doc-#{source_entry_id}",
      search_text: text,
      metadata_text: "",
      content_hash: "hash-#{source_entry_id}",
      first_seen_at: provider_time,
      last_seen_at: provider_time,
      inserted_at: provider_time,
      updated_at: provider_time
    })
  end
end
