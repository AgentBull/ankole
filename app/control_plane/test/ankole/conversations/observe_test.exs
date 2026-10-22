defmodule Ankole.Conversations.ObserveTest do
  alias Ankole.AIGateway.ResponseCommit
  # Serial because the channel-projection test leaves the sandbox with
  # `unboxed_run` to prove real row locking.
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo

  alias Ankole.Signals.Types
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Commands
  alias Ankole.Conversations.Conversation, as: PublicConversation
  alias Ankole.Conversations.External
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Observation
  alias Ankole.Conversations.Attachments
  import Ankole.Conversations.Assertions
  alias Ankole.Conversations.Message, as: ConversationMessage
  alias Ankole.Conversations.ExternalMessageRef

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ecto.Query

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "ingress attribute keys" do
    test "raises when an internal fact constructor receives an unknown field" do
      assert_raise KeyError, fn ->
        Observation.entry(%{
          agent_uid: "unused-agent",
          binding_name: "lark-main",
          adapter: "lark",
          source_event_id: "unknown-field-event",
          unknown_key: true
        })
      end
    end

    test "rejects a string-key alias in the internal ingress envelope" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      input = Map.put(group_entry(), "text", "shadow text")

      assert {:error, {:invalid_ingress_attr_key, "text"}} =
               Observe.emit_entry(agent.uid, "lark-main", input, now: @base_time)
    end

    test "rejects string keys in the internal channel envelope" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      input = put_in(group_entry(), [:channel, "kind"], "im_group")

      assert {:error, {:invalid_ingress_channel_attr_key, "kind"}} =
               Observe.emit_entry(agent.uid, "lark-main", input, now: @base_time)
    end

    test "rejects a key collision while it normalizes an ingress JSON field" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      input =
        Map.put(group_entry(), :author, %{:display_name => "atom", "display_name" => "string"})

      assert {:error,
              {:invalid_ingress_json, :author, {:duplicate_normalized_key, "display_name"}}} =
               Observe.emit_entry(agent.uid, "lark-main", input, now: @base_time)
    end
  end

  describe "external conversation observation concurrency" do
    test "serializes metadata merges and keeps last_seen_at monotonic" do
      provider_id = "test:room:#{System.unique_integer([:positive])}"
      first_seen_at = DateTime.add(@base_time, 2, :second)
      older_seen_at = DateTime.add(@base_time, 1, :second)
      parent = self()

      tenant =
        Sandbox.unboxed_run(Repo, fn ->
          Ankole.DataCase.create_committed_tenant(%{
            slug: "observe-" <> Ecto.UUID.generate(),
            display_name: "Observation claim test"
          })
        end)

      Repo.put_tenant_id(tenant.id)

      {agent, worker_provider_id} =
        Sandbox.unboxed_run(Repo, fn ->
          %{principal: agent} = agent_fixture()
          worker = Repo.get!(Ankole.AgentWorkers.AgentWorker, agent.uid)
          {agent, worker.provider_id}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.put_tenant_id(tenant.id)

          :ok = delete_agent_fixture_rows(agent.uid, worker_provider_id)

          refute Repo.get_by(Ankole.AgentWorkers.Providers.Provider,
                   provider_id: worker_provider_id
                 )

          cleanup_tenant!(tenant)
        end)
      end)

      observe = fn repo, metadata, time ->
        External.observe_conversation_in_tx(
          repo,
          %{agent_uid: agent.uid},
          %{
            provider_conversation_id: provider_id,
            external_kind: :im_group,
            reply_mode: :entry,
            metadata: metadata
          },
          time
        )
      end

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %PublicConversation{}} =
                 Repo.transact(fn repo -> observe.(repo, %{"base" => true}, @base_time) end)
      end)

      first =
        Task.async(
          Repo.bind_tenant(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transact(fn repo ->
                result = observe.(repo, %{"first" => true}, first_seen_at)
                send(parent, :first_observation_written)

                receive do
                  :commit_first_observation -> result
                end
              end)
            end)
          end)
        )

      assert_receive :first_observation_written, 5_000

      second =
        Task.async(
          Repo.bind_tenant(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transact(fn repo -> observe.(repo, %{"second" => true}, older_seen_at) end)
            end)
          end)
        )

      refute Task.yield(second, 50)
      send(first.pid, :commit_first_observation)
      assert {:ok, %PublicConversation{}} = Task.await(first, 5_000)
      assert {:ok, %PublicConversation{}} = Task.await(second, 5_000)
      conversation = External.get_conversation(Repo, provider_id)
      assert conversation.metadata == %{"base" => true, "first" => true, "second" => true}
      assert conversation.last_seen_at == first_seen_at
    end
  end

  describe "binding policy and actor handoff" do
    test "ignore skips unaddressed group entries without mirroring or waking" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{status: :ignored}} =
               Observe.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert Repo.aggregate(ConversationMessage, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0
      assert Repo.aggregate(InboundBatch, :count) == 1
    end

    test "record_only mirrors unaddressed group entries without signal" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      assert {:ok,
              %{
                status: :recorded,
                message_observation: %{message: entry, external_ref: entry_ref}
              }} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   formatted_content: %{"format" => "markdown", "body" => "hello"}
                 }),
                 now: @base_time
               )

      assert entry.conversation_id == conversation_id!("lark:chat:group-a")
      assert entry_ref.provider_message_id == "msg-1"
      assert entry.text == "hello"
      assert entry.rich_content == nil
      assert entry_ref.provider_thread_id == "thread-1"
      assert Repo.aggregate(Signal, :count) == 0
      assert Repo.aggregate(InboundBatch, :count) == 1
    end

    test "attachments get stable PostgreSQL numeric IDs starting at 10000" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      assert %{rows: [[10_000, 1, 9_007_199_254_740_991]]} =
               SQL.query!(Repo, """
               SELECT start_value, increment_by, max_value
               FROM pg_sequences
               WHERE schemaname = current_schema()
                 AND sequencename = 'conversation_attachment_id_seq'
               """)

      attachment = %{
        provider_ref: "lark:file:file_1",
        provider: "lark",
        file_key: "file_1",
        name: "Alpha九宫格因子分域.md"
      }

      assert {:ok,
              %{
                message_observation: %{message: first_entry, external_ref: _first_entry_ref},
                inbound_batch: first_batch
              }} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{attachments: [attachment]}),
                 now: @base_time
               )

      assert [%{"attachment_id" => attachment_id}] = first_entry.attachments
      assert attachment_id >= 10_000

      assert attachment_id ==
               first_batch.entries
               |> List.first()
               |> get_in(["attachments", Access.at(0), "attachment_id"])

      {:ok, stored} =
        Attachments.store_attachment(%{"name" => "AlphaJiuGongGeYinZiFenYu.md"}, "notes")

      materialized_attachment =
        attachment
        |> Map.put(:attachment_id, attachment_id)
        |> Map.put(:blob_ref, stored["blob_ref"])
        |> Map.put(:path, stored["path"])

      assert {:ok,
              %{
                message_observation: %{
                  message: refreshed_entry,
                  external_ref: _refreshed_entry_ref
                }
              }} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-attachment-materialized",
                   attachments: [materialized_attachment],
                   provider_time: DateTime.add(@base_time, 1, :second)
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert [%{"attachment_id" => ^attachment_id}] = refreshed_entry.attachments

      assert {:ok,
              %{message_observation: %{message: second_entry, external_ref: _second_entry_ref}}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-attachment-2",
                   provider_message_id: "msg-attachment-2",
                   attachments: [
                     %{attachment | provider_ref: "lark:file:file_2", file_key: "file_2"}
                   ],
                   provider_time: DateTime.add(@base_time, 2, :second)
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert [%{"attachment_id" => second_attachment_id}] = second_entry.attachments
      assert second_attachment_id > attachment_id
    end

    test "record_only preserves structured content that adds information beyond text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      rich_content = %{
        "format" => "card",
        "body" => "hello",
        "elements" => [%{"type" => "button", "label" => "Open"}]
      }

      assert {:ok,
              %{
                status: :recorded,
                message_observation: %{message: entry, external_ref: _entry_ref}
              }} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{formatted_content: rich_content}),
                 now: @base_time
               )

      assert entry.text == "hello"
      assert entry.rich_content == rich_content
    end

    test "addressed intake keeps current message identity and leaves shared history to Runtime" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      assert {:ok, %{status: :accepted, inbound_batch: batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-current-addressed",
                   provider_message_id: "msg-current-addressed",
                   provider_thread_id: "thread-current",
                   explicit: true,
                   text: "你来回答我上个问题"
                 }),
                 now: @base_time
               )

      insert_message_observation!(
        "msg-prior-question",
        "这个排版为什么能做这么好？",
        DateTime.add(@base_time, -2, :second),
        %{principal_uid: "bob", id: "ou_bob", display_name: "Bob"},
        "thread-prior-question"
      )

      insert_message_observation!(
        "msg-other-agent-answer",
        "是按既有技能和现场内容一起组织的。",
        DateTime.add(@base_time, -1, :second),
        %{agent_uid: "other-agent", display_name: "Research Agent"},
        "thread-other-agent"
      )

      assert {:ok, [%{status: :accepted, signal: input}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      refute Map.has_key?(input.data, "channel_context")

      current =
        message_snapshot!(
          conversation_id: input.conversation_id,
          provider_message_id: "msg-current-addressed"
        )

      assert input.message_id == current.id
      assert input.data["message_ids"] == [current.id]

      assert message_snapshot!(
               conversation_id: input.conversation_id,
               provider_message_id: "msg-prior-question"
             ).text == "这个排版为什么能做这么好？"

      assert message_snapshot!(
               conversation_id: input.conversation_id,
               provider_message_id: "msg-other-agent-answer"
             ).text == "是按既有技能和现场内容一起组织的。"
    end

    test "bare mention leaves the preceding question available as unread history" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-observed-question",
                   provider_message_id: "msg-observed-question",
                   provider_thread_id: nil,
                   text: "现在你接入的大模型是什么呢？"
                 }),
                 now: @base_time
               )

      # The observe-only batch closes long before the bare mention arrives.
      assert {:ok, _finalized} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 5, :second))

      assert {:ok, %{status: :accepted, inbound_batch: batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-bare-mention",
                   provider_message_id: "msg-bare-mention",
                   provider_thread_id: nil,
                   explicit: true,
                   text: nil,
                   mentions: [%{kind: "agent", structured: true, agent_uid: agent.uid}],
                   provider_time: DateTime.add(@base_time, 10, :second)
                 }),
                 now: DateTime.add(@base_time, 10, :second)
               )

      assert {:ok, [%{status: :accepted, signal: input}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      assert input.type == "conversation.message.addressed"
      assert get_in(input.data, ["entry", "text"]) == ""

      refute Map.has_key?(input.data, "channel_context")

      prior =
        message_snapshot!(
          conversation_id: input.conversation_id,
          provider_message_id: "msg-observed-question"
        )

      assert prior.text == "现在你接入的大模型是什么呢？"
      refute prior.id in input.data["message_ids"]
    end

    test "intake leaves branch visibility to Runtime and stores no frozen history snapshot" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      %{signal: first_event} =
        emit_addressed_signal(
          agent.uid,
          "lark-main",
          group_entry(%{
            source_event_id: "evt-already-visible-question",
            provider_message_id: "msg-already-visible-question",
            explicit: true,
            text: "本 agent 已经看过的问题"
          }),
          @base_time
        )

      assert {:ok, conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, first_event.session_id)

      response = complete_actor_response!(agent.uid, conversation.id, first_event.id)

      visible_reply =
        insert_message_observation!(
          "msg-already-visible-reply",
          "本 agent 已经给过的回答",
          DateTime.add(@base_time, 1, :second),
          %{agent_uid: agent.uid, display_name: "Target Agent"},
          "thread-visible-reply"
        )

      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.update(
                   Repo.get_by!(ExternalMessageRef, message_id: visible_reply.id),
                   :observe,
                   %{ai_message_id: response.id}
                 )
               end)

      insert_message_observation!(
        "msg-unseen-other-agent",
        "另一个 agent 刚补充的内容",
        DateTime.add(@base_time, 2, :second),
        %{agent_uid: "other-agent", display_name: "Other Agent"},
        "thread-unseen-other-agent"
      )

      %{signal: current_event} =
        emit_addressed_signal(
          agent.uid,
          "lark-main",
          group_entry(%{
            source_event_id: "evt-context-dedupe-current",
            provider_message_id: "msg-context-dedupe-current",
            provider_thread_id: "thread-current",
            provider_time: DateTime.add(@base_time, 3, :second),
            explicit: true,
            text: "继续"
          }),
          DateTime.add(@base_time, 3, :second)
        )

      refute Map.has_key?(current_event.data, "channel_context")

      current =
        message_snapshot!(
          conversation_id: current_event.conversation_id,
          provider_message_id: "msg-context-dedupe-current"
        )

      assert current_event.data["message_ids"] == [current.id]

      assert message_snapshot!(
               conversation_id: current_event.conversation_id,
               provider_message_id: "msg-unseen-other-agent"
             ).text == "另一个 agent 刚补充的内容"
    end

    test "may_intervene mirrors and finalizes a delayed ambient observation input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      due_at = DateTime.add(@base_time, 15_000, :millisecond)

      assert batch.available_at == due_at
      assert Repo.aggregate(Signal, :count) == 0

      assert {:ok, [%{status: :accepted, signal: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert input.type == "im.message.may_intervene"
      assert input.available_at == due_at

      assert [%{"speaker" => "Alice", "sent_at" => sent_at, "text" => "hello"}] =
               input.data["observed_messages"]

      assert sent_at == DateTime.to_iso8601(@base_time)
      assert input.sender_key == nil
    end

    test "an inbound batch finalizes once due and waits when it is not due" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert Repo.aggregate(Signal, :count) == 0

      early = DateTime.add(batch.available_at, -1, :millisecond)

      assert {:ok, %{status: :not_due, available_at: due_at}} =
               Ankole.Conversations.InboundBatches.finalize_inbound_batch_by_id(batch.id,
                 now: early
               )

      assert due_at == batch.available_at

      assert {:ok, %{status: :accepted, signal: input}} =
               Ankole.Conversations.InboundBatches.finalize_inbound_batch_by_id(batch.id,
                 now: batch.available_at
               )

      assert input.type == "im.message.may_intervene"
      assert Repo.get!(InboundBatch, batch.id).batch_state == :finalized
    end

    test "may_intervene entries in the same room and thread finalize as one ambient input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: first}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-first",
                   provider_message_id: "msg-ambient-first",
                   text: "first"
                 }),
                 now: @base_time
               )

      second_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{inbound_batch: second}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-second",
                   provider_message_id: "msg-ambient-second",
                   text: "second"
                 }),
                 now: second_at
               )

      due_at = DateTime.add(second_at, 15_000, :millisecond)
      merged = Repo.get!(InboundBatch, first.id)

      assert first.id == second.id
      assert Repo.aggregate(Signal, :count) == 0
      assert merged.available_at == due_at

      assert [
               %{"provider_message_id" => "msg-ambient-first", "text" => "first"},
               %{"provider_message_id" => "msg-ambient-second", "text" => "second"}
             ] = merged.entries

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert [
               %{"speaker" => "Alice", "text" => "first"},
               %{"speaker" => "Alice", "text" => "second"}
             ] = input.data["observed_messages"]

      assert %Signal{id: id} =
               Queue.next_ready_event(
                 agent.uid,
                 Ankole.Sessions.Key.conversation(conversation_id!("lark:chat:group-a")),
                 due_at
               )

      assert id == input.id
    end

    test "ambient observation recall only uses provider-visible signal mirrors" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      {:ok, room} =
        Repo.transact(fn repo ->
          External.observe_conversation_in_tx(
            repo,
            %{agent_uid: agent.uid},
            %{provider_conversation_id: "lark:chat:group-a", external_kind: :im_group},
            @base_time
          )
        end)

      session_id = Ankole.Sessions.Key.conversation(room.id)
      assert {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)

      Repo.insert!(%Message{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        type: :message,
        status: :complete,
        content: [%{"text" => "internal assistant row"}],
        metadata: %{
          "conversation_id" => "lark:chat:group-a",
          "provider_message_id" => "internal-row",
          "provider_thread_id" => "thread-1"
        },
        inserted_at: @base_time,
        updated_at: @base_time
      })

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      assert {:ok, [%{status: :accepted, signal: input}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      observed = input.data["observed_messages"]

      assert [%{"provider_message_id" => "msg-1", "text" => "hello"}] = observed
      refute Enum.any?(observed, &(&1["source"] == "ai_gateway_messages"))
      refute Enum.any?(observed, &(&1["text"] == "internal assistant row"))
    end

    test "may_intervene payload includes pre-batch transcript and unreplied ambient context" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{status: :recorded, inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)

      insert_message_observation!(
        "msg-history-old",
        "old transcript context",
        DateTime.add(@base_time, -12, :second)
      )

      insert_message_observation!(
        "msg-history-agent",
        "previous agent answer",
        DateTime.add(@base_time, -10, :second),
        %{agent_uid: agent.uid, display_name: "Research Agent"}
      )

      insert_message_observation!(
        "msg-backlog-1",
        "this strategy might be worth a backtest",
        DateTime.add(@base_time, -8, :second),
        %{principal_uid: "bob", id: "ou_bob", display_name: "Bob"}
      )

      insert_message_observation!(
        "msg-backlog-2",
        "which benchmark should we use?",
        DateTime.add(@base_time, -7, :second),
        %{principal_uid: "carol", id: "ou_carol", display_name: "Carol"}
      )

      insert_message_observation!(
        "msg-other-thread",
        "different thread",
        DateTime.add(@base_time, -6, :second),
        %{principal_uid: "dave", id: "ou_dave", display_name: "Dave"},
        "thread-2"
      )

      assert {:ok, [%{status: :accepted, signal: input}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      assert get_in(input.data, ["entry", "text"]) ==
               "[#{DateTime.to_iso8601(@base_time)} Alice] hello"

      assert [
               %{"role" => "human", "text" => "old transcript context"},
               %{"role" => "agent", "text" => "previous agent answer"},
               %{"role" => "human", "text" => "this strategy might be worth a backtest"},
               %{"role" => "human", "text" => "which benchmark should we use?"},
               %{"role" => "human", "text" => "different thread"},
               %{"role" => "human", "text" => "hello"}
             ] = get_in(input.data, ["observed_messages"])

      assert input.data["backdrop_messages"] == []

      assert [
               %{"text" => "this strategy might be worth a backtest"},
               %{"text" => "which benchmark should we use?"},
               %{"text" => "different thread"}
             ] = get_in(input.data, ["unreplied_messages"])
    end

    test "upgraded ignore batch mirroring does not overwrite newer provider state" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: %{uid: bob_uid}} = human_fixture()
      bob = provider_author_fixture(bob_uid, "provider-bob", %{display_name: "Bob"})

      assert {:ok, %{status: :ignored, inbound_batch: neutral_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-stale-batch-old",
                   provider_message_id: "msg-stale-batch-old",
                   text: "old batch text",
                   author: bob,
                   provider_time: @base_time
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(ConversationMessage, :count) == 0

      newer_time = DateTime.add(@base_time, 5, :second)

      assert {:ok, newer_fact} =
               Observation.entry(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 adapter: "lark",
                 source_event_id: "evt-stale-batch-newer",
                 provider_conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-stale-batch-old",
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
                 conversation =
                   External.get_conversation(repo, newer_fact.provider_conversation_id)

                 fact = %{
                   newer_fact
                   | conversation_id: conversation.id,
                     session_id: Ankole.Sessions.Key.conversation(conversation.id)
                 }

                 External.observe_entry_in_tx(repo, fact, newer_time)
               end)

      mention_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-stale-batch-trigger",
                   provider_message_id: "msg-stale-batch-trigger",
                   explicit: true,
                   text: "@bot help",
                   author: bob,
                   provider_time: mention_at
                 }),
                 now: mention_at
               )

      assert addressed_batch.id == neutral_batch.id
      assert addressed_batch.mode == :addressed

      assert {:ok, [%{status: :accepted}]} =
               finalize_due_inbound_batch_events(now: addressed_batch.available_at)

      assert %{text: "new provider text", provider_time: ^newer_time} =
               message_snapshot!(
                 conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-stale-batch-old"
               )
    end

    test "may_intervene batch removal drops only the recalled source entry" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :may_intervene)

      assert {:ok, %{inbound_batch: first}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-remove-first",
                   provider_message_id: "msg-ambient-remove-first",
                   text: "first"
                 }),
                 now: @base_time
               )

      second_at = DateTime.add(@base_time, 250, :millisecond)

      assert {:ok, %{inbound_batch: second}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-ambient-remove-second",
                   provider_message_id: "msg-ambient-remove-second",
                   text: "second"
                 }),
                 now: second_at
               )

      assert first.id == second.id

      assert {:ok, %{updated_inbound_batches: 1, lifecycle_events: []}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "lark-main",
                 lifecycle_entry(%{
                   source_event_id: "recall-ambient-remove-first",
                   provider_message_id: "msg-ambient-remove-first"
                 }),
                 now: DateTime.add(@base_time, 500, :millisecond)
               )

      updated = Repo.get!(InboundBatch, first.id)

      assert [%{"provider_message_id" => "msg-ambient-remove-second", "text" => "second"}] =
               updated.entries

      due_at = updated.available_at

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert input.type == "im.message.may_intervene"

      assert [%{"provider_message_id" => "msg-ambient-remove-second", "text" => "second"}] =
               get_in(input.data, ["observed_messages"])

      assert %InboundBatch{
               batch_state: :finalized,
               entries: [%{"provider_message_id" => "msg-ambient-remove-second"}]
             } = Repo.get!(InboundBatch, first.id)
    end

    test "removing the addressed trigger downgrades a pending ignore batch to no signal" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: %{uid: bob_uid}} = human_fixture()
      bob = provider_author_fixture(bob_uid, "provider-bob", %{display_name: "Bob"})

      assert {:ok, %{status: :ignored, inbound_batch: neutral_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-neutral-before-recall",
                   provider_message_id: "msg-neutral-before-recall",
                   author: bob,
                   text: "context before mention"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-recalled-mention",
                   provider_message_id: "msg-recalled-mention",
                   author: bob,
                   text: "@Agent please ignore this after recall",
                   mentions: [%{kind: "agent", structured: true, agent_uid: agent.uid}]
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert addressed_batch.id == neutral_batch.id
      assert addressed_batch.mode == :addressed

      assert {:ok, %{updated_inbound_batches: 1, lifecycle_events: []}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "recall-addressed-trigger",
                   provider_message_id: "msg-recalled-mention"
                 }),
                 now: DateTime.add(@base_time, 200, :millisecond)
               )

      updated = Repo.get!(InboundBatch, neutral_batch.id)

      assert updated.mode == :neutral
      assert is_nil(updated.requester_sender_key)

      assert [%{"provider_message_id" => "msg-neutral-before-recall"}] = updated.entries

      assert {:ok, [%{status: :ignored, inbound_batch: finalized}]} =
               finalize_due_inbound_batch_events(now: updated.available_at)

      assert finalized.batch_state == :finalized
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "DM and structured mentions are explicit even when group policy is ignore" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{inbound_batch: dm_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-dm",
                   provider_message_id: "dm-msg-1",
                   provider_conversation_id: "lark:dm:alice-agent",
                   channel: %{kind: :im_dm, reply_mode: :entry},
                   text: "dm"
                 }),
                 now: @base_time
               )

      assert {:ok, [%{signal: dm_input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 1_000, :millisecond)
               )

      assert dm_input.type == "conversation.message.addressed"
      assert dm_batch.mode == :addressed

      assert External.get_conversation(Repo, "lark:dm:alice-agent").metadata[
               "dm_peer_principal_uid"
             ] ==
               dm_input.sender_key

      # A provider cannot claim internal Agent authority or replace the DM peer.
      assert {:error, {:invalid_ingress_author_authority, "principal_uid"}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-dm-self-echo",
                   provider_message_id: "dm-msg-self-echo",
                   provider_conversation_id: "lark:dm:alice-agent",
                   channel: %{kind: :im_dm, reply_mode: :entry},
                   author: %{
                     principal_uid: agent.uid,
                     id: "provider-agent",
                     display_name: "Agent"
                   },
                   text: "provider echo"
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert External.get_conversation(Repo, "lark:dm:alice-agent").metadata[
               "dm_peer_principal_uid"
             ] ==
               dm_input.sender_key

      assert {:ok, %{inbound_batch: mention_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-mention",
                   provider_message_id: "msg-mention",
                   text: "@Agent do this",
                   mentions: [%{kind: "agent", structured: true, agent_uid: agent.uid}]
                 }),
                 now: @base_time
               )

      assert {:ok, [%{signal: mention_input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 1_000, :millisecond)
               )

      assert mention_input.type == "conversation.message.addressed"
      assert mention_batch.mode == :addressed
    end

    test "unmentioned group replies do not become addressed input without a real runtime match" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore)

      assert {:ok, %{status: :ignored, inbound_batch: batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{reply_to_provider_message_id: "missing-target"}),
                 now: @base_time
               )

      assert {:ok, [%{status: :ignored, inbound_batch: finalized}]} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 600, :millisecond))

      assert finalized.id == batch.id
      assert batch.mode == :neutral
      assert batch.reply_to_provider_message_id == "missing-target"
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "replying to this agent is addressed and carries an immutable target snapshot" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :record_only)

      Ankole.ExternalConversationsFixtures.external_conversation_fixture("lark:chat:group-a")

      target =
        insert_message_observation!(
          "msg-agent-report",
          "Yesterday's complete report",
          @base_time,
          %{agent_uid: agent.uid, display_name: "Research Agent"}
        )

      reply_time = DateTime.add(@base_time, 1, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: reply_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-compare-quality",
                   provider_message_id: "msg-compare-quality",
                   reply_to_provider_message_id: "msg-agent-report",
                   text: "Why was today's work lower quality?"
                 }),
                 now: reply_time
               )

      assert target.provider_message_id == "msg-agent-report"
      assert reply_batch.mode == :addressed
      assert reply_batch.reply_to_provider_message_id == "msg-agent-report"

      assert {:ok, [%{signal: signal}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(reply_time, 1_000, :millisecond)
               )

      assert signal.type == "conversation.message.addressed"

      assert %{
               "provider_message_id" => "msg-agent-report",
               "resolution" => "resolved",
               "role" => "agent",
               "text" => "Yesterday's complete report"
             } = get_in(signal.data, ["entry", "reply_to"])

      assert get_in(signal.data, ["entry", "reply_to_provider_message_id"]) ==
               "msg-agent-report"

      assert %{reply_to_provider_message_id: "msg-agent-report"} =
               message_snapshot!(
                 conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-compare-quality"
               )
    end

    test "a human reply in a thread the agent joined is addressed under record_only" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "slack-main", :record_only, adapter: "slack")
      channel_id = "slack:C1"

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(
                 agent.uid,
                 "slack-main",
                 group_entry(%{
                   source_event_id: "evt-thread-root",
                   provider_message_id: "msg-thread-root",
                   provider_conversation_id: channel_id,
                   provider_thread_id: nil,
                   text: "Start a thread"
                 }),
                 now: @base_time
               )

      thread_id = "slack:C1:msg-thread-root"

      assert {:ok, %{status: :sent, provider_thread_id: ^thread_id}} =
               commit_and_dispatch(
                 agent.uid,
                 "slack-main",
                 %{
                   outbound_key: "agent-thread-reply",
                   operation: :reply,
                   conversation_id: conversation_id!(channel_id),
                   reply_to_provider_message_id: "msg-thread-root",
                   fallback_visible_text: "Agent reply"
                 },
                 [:reply_entry],
                 %{
                   created_provider_message_id: "msg-agent-thread-reply",
                   provider_thread_id: thread_id
                 }
               )

      reply_time = DateTime.add(@base_time, 1, :second)

      assert {:ok, %{status: :accepted, inbound_batch: reply_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "slack-main",
                 group_entry(%{
                   source_event_id: "evt-human-thread-reply",
                   provider_message_id: "msg-human-thread-reply",
                   provider_conversation_id: channel_id,
                   provider_thread_id: thread_id,
                   reply_to_provider_message_id: "msg-thread-root",
                   text: "Continue without another mention"
                 }),
                 now: reply_time
               )

      assert reply_batch.mode == :addressed

      assert {:ok, results} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(reply_time, 1_000, :millisecond)
               )

      assert Enum.any?(results, fn
               %{signal: %Signal{type: "conversation.message.addressed"}} -> true
               _result -> false
             end)
    end

    test "reply resolution does not borrow human attachments from another agent binding" do
      %{principal: agent_a} = agent_fixture()
      %{principal: agent_b} = agent_fixture()
      binding_fixture(agent_a.uid, "lark-main", :record_only)
      binding_fixture(agent_b.uid, "lark-main", :ignore)

      {:ok, attachment} =
        Attachments.store_attachment(
          %{"name" => "strategy.pdf", "resource_type" => "file"},
          "pdf"
        )

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(
                 agent_a.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-agent-a-parent",
                   provider_message_id: "msg-agent-a-parent",
                   text: "Shared-room source text",
                   attachments: [attachment]
                 }),
                 now: @base_time
               )

      assert %{attachments: [%{"attachment_id" => attachment_id} = stored_attachment]} =
               message_snapshot!(
                 conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-agent-a-parent"
               )

      assert attachment_id >= 10_000

      assert Map.delete(stored_attachment, "attachment_id") ==
               Map.put(
                 attachment,
                 "path",
                 Ankole.Files.chat_path(conversation_id!("lark:chat:group-a"), attachment["path"])
               )

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 agent_b.uid,
                 "lark-main",
                 group_entry(%{
                   source_event_id: "evt-agent-b-reply",
                   provider_message_id: "msg-agent-b-reply",
                   reply_to_provider_message_id: "msg-agent-a-parent",
                   explicit: true,
                   text: "Please inspect this"
                 }),
                 now: DateTime.add(@base_time, 1, :millisecond)
               )

      assert {:ok, results} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 1_001, :millisecond)
               )

      assert [%{signal: signal}] =
               Enum.filter(results, &Map.has_key?(&1, :signal))

      assert signal.agent_uid == agent_b.uid

      assert %{
               "provider_message_id" => "msg-agent-a-parent",
               "resolution" => "resolved",
               "text" => "Shared-room source text",
               "attachments" => []
             } = get_in(signal.data, ["entry", "reply_to"])
    end

    test "non-IM entries need code-defined signal type instead of addressed IM fallback" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "webhook", :ignore)

      assert {:error, :missing_signal_type} =
               Observe.emit_entry(
                 agent.uid,
                 "webhook",
                 webhook_entry(%{signal_type: nil}),
                 now: @base_time
               )

      assert Repo.aggregate(Signal, :count) == 0
      assert Repo.aggregate(ConversationMessage, :count) == 0
    end

    test "unavailable bindings do not accept ingress even when enabled" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark-main", :ignore, unavailable_reason: "adapter missing")

      assert {:error, {:binding_unavailable, "adapter missing"}} =
               Observe.emit_entry(agent.uid, "lark-main", group_entry(), now: @base_time)
    end

    test "CEL binding filters can admit or filter ingress before mirror and signal writes" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "bot", :ignore,
        filters: %{
          "cel" =>
            "signal.channel.id == 'lark:chat:allowed' && signal.entry.reply_to_provider_message_id == 'msg-parent'"
        }
      )

      assert {:ok, %{status: :filtered}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(ConversationMessage, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0

      %{signal: input} =
        emit_addressed_signal(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            reply_to_provider_message_id: "msg-parent",
            source_event_id: "evt-allowed",
            provider_conversation_id: "lark:chat:allowed",
            provider_message_id: "msg-allowed"
          })
        )

      assert input.conversation_id == conversation_id!("lark:chat:allowed")

      assert get_in(input.data, ["entry", "reply_to_provider_message_id"]) ==
               "msg-parent"

      assert Repo.aggregate(ConversationMessage, :count) == 1
      assert Repo.aggregate(Signal, :count) == 1
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
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   author: %{platform_subject: "lark:user:bob", display_name: "Bob"},
                   text: "goodbye",
                   provider_conversation_id: "lark:chat:allowed"
                 }),
                 now: @base_time
               )

      %{signal: input} =
        emit_addressed_signal(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            author: %{platform_subject: "lark:user:alice", display_name: "Alice"},
            source_event_id: "evt-cel-functions",
            provider_conversation_id: "lark:chat:allowed",
            provider_message_id: "msg-cel-functions"
          })
        )

      assert {:ok, principal} =
               Ankole.Principals.resolve_platform_subject("bot", "lark:user:alice")

      assert input.sender_key == principal.uid
    end

    test "CEL binding filters keep booleans and null as JSON values" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "bot", :ignore,
        filters: %{
          "cel" =>
            "signal.entry.explicit == true && signal.entry.mirror_only == false && signal.entry.thread_id == null"
        }
      )

      %{signal: input} =
        emit_addressed_signal(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            provider_thread_id: nil,
            source_event_id: "evt-cel-json-values",
            provider_message_id: "msg-cel-json-values"
          })
        )

      assert input.provider_message_id == "msg-cel-json-values"
    end

    test "invalid CEL filters fail before durable writes" do
      %{principal: agent} = agent_fixture()

      binding_fixture(agent.uid, "runtime-error", :ignore,
        filters: %{"cel" => "signal.entry.missing == true"}
      )

      assert {:error, {:invalid_binding_filter, reason}} =
               Observe.emit_entry(
                 agent.uid,
                 "runtime-error",
                 group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert reason =~ "signal filter execution failed"

      assert {:error, changeset} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: "bad-shape",
                 adapter: "lark",
                 config_ref: "app-config://bad-shape",
                 filters: %{"eq" => %{"conversation_id" => "x"}},
                 unaddressed_group_message_policy: :ignore,
                 unmatched_sender_policy: :create_standalone
               })

      assert %{filters: [_]} = errors_on(changeset)

      assert Repo.aggregate(ConversationMessage, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0
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
                 display_name: "Alice",
                 metadata: %{"tenant_key" => "tenant-a"}
               })

      assert {:ok, _} = Ecto.UUID.cast(observed.principal.uid)
      assert observed.identity.provider == "lark-main"
      assert observed.identity.external_id == "ou_alice"
    end

    test "entry ingress enriches known platform subject authors with principal uid" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: %{uid: alice_uid}} =
        platform_subject_fixture(
          provider: "bot",
          external_id: "ou_alice",
          display_name: "Alice"
        )

      %{signal: input} =
        emit_addressed_signal(
          agent.uid,
          "bot",
          group_entry(%{
            source_event_id: "evt-known-author",
            provider_message_id: "msg-known-author",
            explicit: true,
            author: %{platform_subject: "ou_alice", display_name: "Alice"}
          })
        )

      assert input.sender_key == alice_uid

      assert %{author: %{"principal_uid" => ^alice_uid, "platform_subject" => "ou_alice"}} =
               message_snapshot!(
                 conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-known-author"
               )
    end
  end

  describe "mirror identity and route-scoped delivery" do
    test "same physical channel and entry share one mirror row while signal remains per binding" do
      %{principal: agent_a} = agent_fixture()
      %{principal: agent_b} = agent_fixture()
      binding_fixture(agent_a.uid, "bot-a", :ignore)
      binding_fixture(agent_b.uid, "bot-b", :ignore)

      explicit = group_entry(%{explicit: true})

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent_a.uid, "bot-a", explicit, now: @base_time)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 agent_b.uid,
                 "bot-b",
                 %{explicit | source_event_id: "evt-1-b"},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert Repo.aggregate(ConversationMessage, :count) == 1

      assert {:ok, [%{signal: _input_a}, %{signal: _input_b}]} =
               finalize_due_inbound_batch_events(now: DateTime.add(@base_time, 2, :second))

      assert Repo.aggregate(Signal, :count) == 2

      assert Repo.aggregate(
               from(input in Signal, where: input.agent_uid == ^agent_a.uid),
               :count
             ) == 1

      assert Repo.aggregate(
               from(input in Signal, where: input.agent_uid == ^agent_b.uid),
               :count
             ) == 1
    end

    test "different provider entry ids are not guessed as duplicates" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-2",
                   provider_message_id: "provider-specific-msg-2"
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(ConversationMessage, :count) == 2
    end
  end

  describe "commands and inbound IM batching" do
    test "recognized commands stay typed command events and steer maps through code" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{signal: compress_event}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, text: "/compress release notes"}),
                 now: @base_time
               )

      assert compress_event.type == "command.compress"
      assert compress_event.type == "command.compress"
      assert compress_event.data["command"]["argsText"] == "release notes"

      assert {:ok, %{signal: input}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-steer-1",
                   provider_message_id: "msg-steer-1",
                   text: "/steer be concise"
                 }),
                 now: @base_time
               )

      assert input.type == "command.steer"
      assert input.available_at == @base_time
      assert input.type == "command.steer"
      assert input.data["command"]["argsText"] == "be concise"
      refute Map.has_key?(input.data["command"], "status")
    end

    test "unmirrored durable reply makes a group reply retry explicit and rebases its session" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      target = append_retry_target!(agent.uid, "bot", "cron:schedule-1")
      insert_durable_reply_surface!(target, "bot", "dead-letter-card")

      refute message_snapshot(
               conversation_id: "lark:chat:group-a",
               provider_message_id: "dead-letter-card"
             )

      assert {:ok, %{signal: retry_command}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: false,
                   source_event_id: "evt-retry-reply",
                   provider_message_id: "msg-retry-reply",
                   reply_to_provider_message_id: "dead-letter-card",
                   text: "/retry"
                 }),
                 now: @base_time
               )

      assert retry_command.type == "command.retry"
      assert retry_command.session_id == target.session_id

      assert get_in(retry_command.data, ["command", "targetSignalId"]) ==
               target.id

      assert get_in(retry_command.data, ["session", "session_id"]) ==
               target.session_id
    end

    test "explicit signal retry target takes priority over the reply edge" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      explicit_target = append_retry_target!(agent.uid, "bot", "cron:explicit")
      reply_target = append_retry_target!(agent.uid, "bot", "cron:reply")
      insert_durable_reply_surface!(explicit_target, "bot", "explicit-card")
      insert_durable_reply_surface!(reply_target, "bot", "reply-card")

      assert {:ok, %{signal: retry_command}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-retry-explicit",
                   provider_message_id: "msg-retry-explicit",
                   reply_to_provider_message_id: "reply-card",
                   text: "/retry signal::#{explicit_target.id}"
                 }),
                 now: @base_time
               )

      assert retry_command.session_id == explicit_target.session_id

      assert get_in(retry_command.data, ["command", "targetSignalId"]) ==
               explicit_target.id
    end

    test "16-byte noncanonical retry target does not fall back to a valid reply edge" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      reply_target = append_retry_target!(agent.uid, "bot", "cron:reply")
      insert_durable_reply_surface!(reply_target, "bot", "reply-card")

      assert {:ok, %{signal: retry_command}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-retry-invalid",
                   provider_message_id: "msg-retry-invalid",
                   reply_to_provider_message_id: "reply-card",
                   text: "/retry signal::warehouse worker"
                 }),
                 now: @base_time
               )

      assert retry_command.session_id ==
               Ankole.Sessions.Key.conversation(conversation_id!("lark:chat:group-a"))

      assert Map.fetch!(retry_command.data["command"], "targetSignalId") ==
               nil
    end

    test "unresolved reply retry remains in the command session with an explicit nil target" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{signal: retry_command}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-retry-unresolved-reply",
                   provider_message_id: "msg-retry-unresolved-reply",
                   reply_to_provider_message_id: "missing-card",
                   text: "/retry"
                 }),
                 now: @base_time
               )

      assert retry_command.session_id ==
               Ankole.Sessions.Key.conversation(conversation_id!("lark:chat:group-a"))

      assert Map.fetch!(retry_command.data["command"], "targetSignalId") ==
               nil
    end

    test "top-level bare retry does not guess from an unrelated durable reply" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      target = append_retry_target!(agent.uid, "bot", "cron:schedule-1")
      insert_durable_reply_surface!(target, "bot", "dead-letter-card")

      assert {:ok, %{signal: retry_command}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-retry-bare",
                   provider_message_id: "msg-retry-bare",
                   provider_thread_id: nil,
                   text: "/retry"
                 }),
                 now: @base_time
               )

      assert retry_command.session_id ==
               Ankole.Sessions.Key.conversation(conversation_id!("lark:chat:group-a"))

      refute Map.has_key?(retry_command.data["command"], "targetSignalId")
    end

    test "unsupported commands and full-width slash remain normal addressed text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{signal: undo_input} =
        emit_addressed_signal(
          agent.uid,
          "bot",
          group_entry(%{explicit: true, text: "/undo"})
        )

      assert undo_input.type == "conversation.message.addressed"

      %{signal: full_width_input} =
        emit_addressed_signal(
          agent.uid,
          "bot",
          group_entry(%{
            explicit: true,
            source_event_id: "evt-full-width",
            provider_message_id: "msg-full-width",
            text: "／steer"
          }),
          DateTime.add(@base_time, 1, :second)
        )

      assert full_width_input.type == "conversation.message.addressed"
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

    test "/llm separates help from one-shot profile turns and permits an empty command body" do
      assert {:ok, help} = Commands.classify("/llm")
      assert help == %{"name" => "llm", "raw" => "/llm", "argsText" => ""}

      assert {:ok, empty_body} = Commands.classify("/llm kimi")
      assert empty_body["modelProfile"] == "kimi"
      assert empty_body["argsText"] == ""

      assert {:ok, with_body} =
               Commands.classify("@Agent /llm KIMI   测试",
                 strip_leading_structured_mention: true,
                 structured_mention_prefixes: ["@Agent"]
               )

      assert with_body["modelProfile"] == "kimi"
      assert with_body["argsText"] == "测试"

      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{signal: help_event}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, text: "/llm"}),
                 now: @base_time
               )

      assert help_event.type == "command.llm_help"
      refute Map.has_key?(help_event.data["command"], "modelProfile")
      refute Types.supersedes_pending_interaction?(help_event.type)

      assert {:ok, %{signal: turn_event}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-llm-empty-body",
                   provider_message_id: "msg-llm-empty-body",
                   text: "/llm kimi"
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert turn_event.type == "command.llm"
      assert get_in(turn_event.data, ["command", "modelProfile"]) == "kimi"
      assert get_in(turn_event.data, ["command", "argsText"]) == ""
      assert Types.supersedes_pending_interaction?(turn_event.type)
    end

    test "addressed IM entries close as sender-scoped signal batches" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: %{uid: alice_uid}} = human_fixture()
      alice = provider_author_fixture(alice_uid, "provider-alice", %{display_name: "Alice"})
      %{principal: %{uid: bob_uid}} = human_fixture()
      bob = provider_author_fixture(bob_uid, "provider-bob", %{display_name: "Bob"})

      for {event_id, entry_id, author, offset, text} <- [
            {"evt-a1", "msg-a1", alice, 0, "first"},
            {"evt-a2", "msg-a2", alice, 100, "second"},
            {"evt-b1", "msg-b1", bob, 200, "third"}
          ] do
        assert {:ok, %{status: :accepted}} =
                 Observe.emit_entry(
                   agent.uid,
                   "bot",
                   group_entry(%{
                     explicit: true,
                     source_event_id: event_id,
                     provider_message_id: entry_id,
                     author: author,
                     text: text
                   }),
                   now: DateTime.add(@base_time, offset, :millisecond)
                 )
      end

      assert Repo.aggregate(Signal, :count) == 1

      rows =
        Signal
        |> order_by([input], asc: input.inserted_at)
        |> Repo.all()

      assert Enum.map(rows, & &1.sender_key) == [alice_uid]

      [alice_input] = rows
      assert alice_input.provider_message_id == "msg-a2"
      assert get_in(alice_input.data, ["entry", "text"]) == "first\nsecond"

      assert [
               %{"provider_message_id" => "msg-a1", "text" => "first"},
               %{"provider_message_id" => "msg-a2", "text" => "second"}
             ] = get_in(alice_input.data, ["entries"])

      assert [%InboundBatch{mode: :addressed, requester_sender_key: ^bob_uid} = bob_batch] =
               InboundBatch
               |> where([batch], batch.batch_state == :open)
               |> Repo.all()

      due_at = bob_batch.available_at

      assert {:ok, [%{signal: bob_input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert bob_input.provider_message_id == "msg-b1"
      assert bob_batch.id == Repo.get!(InboundBatch, bob_batch.id).id
    end

    test "duplicate provider deliveries do not duplicate addressed batch text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      first =
        group_entry(%{
          explicit: true,
          source_event_id: "evt-duplicate-delivery-1",
          provider_message_id: "msg-duplicate-delivery",
          text: "@Agent please answer once"
        })

      assert {:ok, %{status: :accepted, inbound_batch: first_batch}} =
               Observe.emit_entry(agent.uid, "bot", first, now: @base_time)

      duplicate_at = DateTime.add(@base_time, 100, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: duplicate_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 %{first | source_event_id: "evt-duplicate-delivery-2"},
                 now: duplicate_at
               )

      assert duplicate_batch.id == first_batch.id
      assert duplicate_batch.available_at == first_batch.available_at
      assert Repo.aggregate(ConversationMessage, :count) == 1

      assert [
               %{
                 "provider_message_id" => "msg-duplicate-delivery",
                 "text" => "@Agent please answer once"
               }
             ] =
               Repo.get!(InboundBatch, first_batch.id).entries

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(now: first_batch.available_at)

      assert input.provider_message_id == "msg-duplicate-delivery"
      assert get_in(input.data, ["entry", "text"]) == "@Agent please answer once"

      assert [%{"provider_message_id" => "msg-duplicate-delivery"}] =
               get_in(input.data, ["entries"])
    end

    test "provider redelivery after batch finalization does not create a second signal" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      fact =
        group_entry(%{
          explicit: true,
          source_event_id: "evt-finalized-redelivery",
          provider_message_id: "msg-finalized-redelivery",
          text: "@Agent please answer once"
        })

      assert {:ok, %{status: :accepted, inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, "bot", fact, now: @base_time)

      assert {:ok, [%{signal: first_event}]} =
               finalize_due_inbound_batch_events(now: batch.available_at)

      assert {:ok, %{status: :duplicate, inbound_batch: nil}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 fact,
                 now: DateTime.add(batch.available_at, 1, :second)
               )

      assert Repo.aggregate(Signal, :count) == 1
      assert Repo.aggregate(InboundBatch, :count) == 1
      assert Repo.get!(Signal, first_event.id).id == first_event.id
    end

    test "newer provider state replaces a pending duplicate batch entry" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      first =
        group_entry(%{
          explicit: true,
          source_event_id: "evt-edited-delivery-1",
          provider_message_id: "msg-edited-delivery",
          text: "@Agent old text",
          provider_time: @base_time
        })

      assert {:ok, %{status: :accepted, inbound_batch: first_batch}} =
               Observe.emit_entry(agent.uid, "bot", first, now: @base_time)

      edited_at = DateTime.add(@base_time, 100, :millisecond)

      assert {:ok, %{status: :accepted, inbound_batch: edited_batch}} =
               Observe.emit_entry(
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
      assert edited_batch.available_at == DateTime.add(edited_at, 1_000, :millisecond)
      assert Repo.aggregate(ConversationMessage, :count) == 1

      assert [
               %{
                 "provider_message_id" => "msg-edited-delivery",
                 "text" => "@Agent corrected text"
               }
             ] =
               Repo.get!(InboundBatch, first_batch.id).entries

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(now: edited_batch.available_at)

      assert input.provider_message_id == "msg-edited-delivery"
      assert get_in(input.data, ["entry", "text"]) == "@Agent corrected text"

      assert %{text: "@Agent corrected text", provider_time: ^edited_at} =
               message_snapshot!(
                 conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-edited-delivery"
               )
    end

    test "one poisoned inbound batch does not block later due batches" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted, inbound_batch: poisoned_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-poisoned-batch",
                   provider_message_id: "msg-poisoned-batch",
                   provider_thread_id: "thread-poisoned",
                   text: "poisoned"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted, inbound_batch: good_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-good-batch",
                   provider_message_id: "msg-good-batch",
                   provider_thread_id: "thread-good",
                   text: "good"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      InboundBatch
      |> where([batch], batch.id == ^poisoned_batch.id)
      |> Repo.update_all(set: [binding_name: ""])

      due_at = good_batch.available_at

      assert {:ok, results} = finalize_due_inbound_batch_events(now: due_at)

      assert Enum.any?(results, &match?(%{status: :finalize_failed}, &1))
      assert %{signal: good_input} = Enum.find(results, &match?(%{signal: _}, &1))
      assert good_input.provider_message_id == "msg-good-batch"
      assert Repo.get!(InboundBatch, good_batch.id).batch_state == :finalized
    end

    test "neutral batch upgrades only the final same-sender run when bot is mentioned" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: %{uid: alice_uid}} = human_fixture()
      alice = provider_author_fixture(alice_uid, "provider-alice", %{display_name: "Alice"})
      %{principal: %{uid: bob_uid}} = human_fixture()
      bob = provider_author_fixture(bob_uid, "provider-bob", %{display_name: "Bob"})

      assert {:ok, %{status: :ignored}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-alice-neutral",
                   provider_message_id: "msg-alice-neutral",
                   author: alice,
                   text: "alice aside"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :ignored}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-bob-neutral",
                   provider_message_id: "msg-bob-neutral",
                   author: bob,
                   text: "bob context"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert {:ok, %{status: :accepted, inbound_batch: addressed_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-bob-mention",
                   provider_message_id: "msg-bob-mention",
                   author: bob,
                   text: "@Agent help",
                   mentions: [%{kind: "agent", structured: true, agent_uid: agent.uid}]
                 }),
                 now: DateTime.add(@base_time, 200, :millisecond)
               )

      assert addressed_batch.mode == :addressed
      assert addressed_batch.requester_sender_key == bob_uid

      due_at = addressed_batch.available_at

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(now: due_at)

      assert get_in(input.data, ["entry", "text"]) == "bob context\n@Agent help"

      assert [
               %{"provider_message_id" => "msg-bob-neutral"},
               %{"provider_message_id" => "msg-bob-mention"}
             ] = get_in(input.data, ["entries"])

      refute message_snapshot(
               conversation_id: "lark:chat:group-a",
               provider_message_id: "msg-alice-neutral"
             )
    end

    test "inline finalized addressed batch does not start preview before turn dispatch" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: %{uid: alice_uid}} = human_fixture()
      alice = provider_author_fixture(alice_uid, "provider-alice", %{display_name: "Alice"})
      %{principal: %{uid: bob_uid}} = human_fixture()
      bob = provider_author_fixture(bob_uid, "provider-bob", %{display_name: "Bob"})

      assert {:ok, %{status: :accepted, inbound_batch: first_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-inline-preview-alice",
                   provider_message_id: "msg-inline-preview-alice",
                   author: alice,
                   text: "@Agent first"
                 }),
                 now: @base_time
               )

      assert Repo.aggregate(Signal, :count) == 0

      assert {:ok,
              %{
                status: :accepted,
                inbound_batch: second_batch,
                finalized_signals: [first_event]
              }} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-inline-preview-bob",
                   provider_message_id: "msg-inline-preview-bob",
                   author: bob,
                   text: "@Agent second"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert second_batch.id != first_batch.id
      assert first_event.type == "conversation.message.addressed"
      assert get_in(first_event.data, ["entry", "text"]) == "@Agent first"
      assert Ankole.Conversations.Delivery.Preview.lookup(first_event.id) == []
    end

    test "addressed text followed by attachment waits on the attachment window and merges" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{inbound_batch: first_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-text",
                   provider_message_id: "msg-text",
                   text: "look at this"
                 }),
                 now: @base_time
               )

      attachment_at = DateTime.add(@base_time, 500, :millisecond)

      assert {:ok, %{inbound_batch: updated_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-image",
                   provider_message_id: "msg-image",
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

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(attachment_at, 1_200, :millisecond)
               )

      assert get_in(input.data, ["entry", "text"]) == "look at this\nimage"

      assert [
               %{
                 "provider_ref" => "lark:image:image-1",
                 "source_message_id" => "msg-image",
                 "name" => "chart.png"
               }
             ] =
               get_in(input.data, ["entry", "attachments"])
    end

    test "pending attachment materialization fences the batch and keeps the original quiet anchor" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{inbound_batch: first_batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-pending-text",
                   provider_message_id: "msg-pending-text",
                   text: "inspect this"
                 }),
                 now: @base_time
               )

      attachment_at = DateTime.add(@base_time, 500, :millisecond)

      pending =
        group_entry(%{
          source_event_id: "evt-pending-image",
          provider_message_id: "msg-pending-image",
          text: nil,
          attachments: [
            %{
              provider_ref: "lark:image:pending-image",
              source_message_id: "msg-pending-image",
              resource_type: "image"
            }
          ],
          metadata: Attachments.put_attachment_materialization(%{}, "pending", attachment_at)
        })

      assert {:ok, %{inbound_batch: pending_batch}} =
               Observe.emit_entry(agent.uid, "bot", pending, now: attachment_at)

      assert pending_batch.id == first_batch.id

      assert pending_batch.available_at ==
               DateTime.add(attachment_at, 4_000, :millisecond)

      materialized_at = DateTime.add(attachment_at, 2_000, :millisecond)
      {:ok, stored} = Attachments.store_attachment(%{"name" => "chart.png"}, "png")
      materialized_path = stored["path"]

      materialized =
        pending
        |> Map.put(
          :metadata,
          Attachments.put_attachment_materialization(pending.metadata, "complete", attachment_at)
        )
        |> put_in([:attachments, Access.at(0), :blob_ref], stored["blob_ref"])
        |> put_in([:attachments, Access.at(0), :path], materialized_path)

      assert {:ok, %{inbound_batch: materialized_batch}} =
               Observe.emit_entry(agent.uid, "bot", materialized, now: materialized_at)

      assert materialized_batch.available_at ==
               DateTime.add(attachment_at, 1_200, :millisecond)

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(now: materialized_at)

      assert get_in(input.data, ["entry", "text"]) == "inspect this"
      drive_path = Ankole.Files.chat_path(input.conversation_id, materialized_path)

      assert [
               %{
                 "path" => ^drive_path,
                 "provider_ref" => "lark:image:pending-image"
               }
             ] =
               get_in(input.data, ["entry", "attachments"])
               |> Enum.map(&Map.take(&1, ["path", "provider_ref"]))
    end

    test "materialization after the batch hard cap refreshes the open signal" do
      {:ok, stored} = Attachments.store_attachment(%{"name" => "slow-image.png"}, "slow png")
      # The owning transaction keeps input delivery pending while its content is revised.
      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 %{principal: agent} = agent_fixture()
                 binding_fixture(agent.uid, "bot", :ignore)

                 observed_at = DateTime.to_iso8601(@base_time)

                 pending =
                   group_entry(%{
                     explicit: true,
                     source_event_id: "evt-slow-image",
                     provider_message_id: "msg-slow-image",
                     text: "inspect this image",
                     attachments: [
                       %{
                         provider_ref: "lark:image:slow-image",
                         source_message_id: "msg-slow-image",
                         resource_type: "image"
                       }
                     ],
                     metadata: %{
                       "attachment_materialization" => %{
                         "state" => "pending",
                         "observed_at" => observed_at
                       }
                     }
                   })

                 assert {:ok, %{inbound_batch: pending_batch}} =
                          Observe.emit_entry(agent.uid, "bot", pending, now: @base_time)

                 assert {:ok, [%{signal: pending_event}]} =
                          Repo.transact(fn _repo ->
                            finalize_due_inbound_batch_events(now: pending_batch.available_at)
                          end)

                 materialized_at = DateTime.add(pending_batch.available_at, 1, :second)

                 materialized_path = stored["path"]

                 materialized =
                   pending
                   |> put_in([:metadata, "attachment_materialization", "state"], "complete")
                   |> put_in([:attachments, Access.at(0), :blob_ref], stored["blob_ref"])
                   |> put_in([:attachments, Access.at(0), :path], materialized_path)

                 assert {:ok,
                         %{
                           status: :input_superseded,
                           signal: refreshed_event
                         }} =
                          Observe.emit_entry(agent.uid, "bot", materialized, now: materialized_at)

                 assert refreshed_event.id == pending_event.id
                 assert refreshed_event.available_at == materialized_at
                 assert Repo.aggregate(Signal, :count) == 1
                 assert Repo.aggregate(InboundBatch, :count) == 1

                 drive_path =
                   Ankole.Files.chat_path(refreshed_event.conversation_id, materialized_path)

                 assert [
                          %{
                            "path" => ^drive_path,
                            "provider_ref" => "lark:image:slow-image"
                          }
                        ] =
                          get_in(refreshed_event.data, ["entry", "attachments"])
                          |> Enum.map(&Map.take(&1, ["path", "provider_ref"]))

                 redelivered_at = DateTime.add(materialized_at, 1, :second)

                 assert {:ok, %{status: :duplicate}} =
                          Observe.emit_entry(agent.uid, "bot", materialized, now: redelivered_at)

                 assert Repo.get!(Signal, refreshed_event.id).available_at == materialized_at
                 {:ok, :verified}
               end)
    end

    test "single addressed message over the normal text budget is not split" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      long_text = String.duplicate("x", 4_500)

      assert {:ok, %{inbound_batch: batch}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   text: long_text
                 }),
                 now: @base_time
               )

      assert [%{"text" => ^long_text}] = batch.entries

      assert {:ok, [%{signal: input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 2_000, :millisecond)
               )

      assert get_in(input.data, ["entry", "text"]) == long_text
      assert [_one_entry] = get_in(input.data, ["entries"])
    end
  end

  describe "attachment observation surface" do
    test "task capacity failure preserves pending media for redelivery and reuses completed bytes" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      input =
        group_entry(%{
          source_event_id: "evt-deferred-image",
          provider_message_id: "msg-deferred-image",
          metadata: %{},
          attachments: [%{"provider_ref" => "lark:image:deferred", "name" => "chart.png"}]
        })

      emit = &Observe.emit_entry(agent.uid, "bot", &1)
      supervisor = start_supervised!({Task.Supervisor, max_children: 0})

      assert {:error, :max_children} =
               Observe.emit_entry_deferred(
                 input,
                 emit,
                 fn _ -> flunk("download must not start without a task") end,
                 &Task.Supervisor.start_child(supervisor, &1),
                 []
               )

      assert %{attachments: [pending], metadata: metadata} =
               message_snapshot!(
                 conversation_id: input.provider_conversation_id,
                 provider_message_id: input.provider_message_id
               )

      assert metadata["attachment_materialization"]["state"] == "pending"
      observed_at = metadata["attachment_materialization"]["observed_at"]
      attachment_id = pending["attachment_id"]
      assert is_integer(attachment_id)
      refute Attachments.stored?(pending)
      owner = self()

      materialize = fn attachments ->
        Attachments.materialize_attachments(attachments, "fixture", fn _attachment ->
          {:ok,
           %{body: "image bytes", filename: "chart.png", content_type: "image/png", put: %{}}}
        end)
      end

      assert {:ok, _pending} =
               Observe.emit_entry_deferred(
                 input,
                 emit,
                 materialize,
                 fn task -> Task.start(fn -> send(owner, {:materialized, task.()}) end) end,
                 []
               )

      assert_receive {:materialized, {:ok, _complete}}, 5_000

      assert %{attachments: [stored], metadata: metadata} =
               message_snapshot!(
                 conversation_id: input.provider_conversation_id,
                 provider_message_id: input.provider_message_id
               )

      assert metadata["attachment_materialization"] == %{
               "state" => "complete",
               "observed_at" => observed_at
             }

      assert stored["attachment_id"] == attachment_id
      assert {:ok, _reference, "image bytes"} = Ankole.Files.read(agent.uid, stored["path"])

      assert {:ok, %{message_observation: %{message: %{attachments: [^stored]}}}} =
               Observe.emit_entry_deferred(
                 input,
                 emit,
                 fn _ -> flunk("stored bytes must be reused") end,
                 fn _ -> flunk("stored bytes need no download task") end,
                 []
               )
    end

    test "a later observation without stored bytes never replaces a stored attachment" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)
      observed_at = DateTime.add(@base_time, 500, :millisecond)

      pending =
        group_entry(%{
          source_event_id: "evt-guarded-image",
          provider_message_id: "msg-guarded-image",
          text: nil,
          attachments: [
            %{provider_ref: "lark:image:guarded", source_message_id: "msg-guarded-image"}
          ],
          metadata: Attachments.put_attachment_materialization(%{}, "pending", observed_at)
        })

      assert {:ok, _pending} = Observe.emit_entry(agent.uid, "bot", pending, now: observed_at)

      %{attachments: [%{"attachment_id" => attachment_id}]} =
        message_snapshot!(
          conversation_id: "lark:chat:group-a",
          provider_message_id: "msg-guarded-image"
        )

      {:ok, stored} = Attachments.store_attachment(%{"name" => "chart.png"}, <<137, 80, 78, 71>>)
      path = stored["path"]

      complete =
        pending
        |> Map.put(
          :metadata,
          Attachments.put_attachment_materialization(%{}, "complete", observed_at)
        )
        |> put_in([:attachments, Access.at(0), :blob_ref], stored["blob_ref"])
        |> put_in([:attachments, Access.at(0), :path], path)
        |> put_in([:attachments, Access.at(0), :materialization_state], "complete")

      assert {:ok, _complete} =
               Observe.emit_entry(agent.uid, "bot", complete,
                 now: DateTime.add(observed_at, 1, :second)
               )

      failed =
        pending
        |> Map.put(
          :metadata,
          Attachments.put_attachment_materialization(%{}, "failed", observed_at)
        )
        |> put_in([:attachments, Access.at(0), :materialization_state], "failed")

      assert {:ok, _late} =
               Observe.emit_entry(agent.uid, "bot", failed,
                 now: DateTime.add(observed_at, 2, :second)
               )

      assert %{attachments: [kept]} =
               message_snapshot!(
                 conversation_id: "lark:chat:group-a",
                 provider_message_id: "msg-guarded-image"
               )

      assert kept["attachment_id"] == attachment_id
      drive_path = Ankole.Files.chat_path(conversation_id!("lark:chat:group-a"), path)
      assert kept["path"] == drive_path
      assert kept["blob_ref"] == stored["blob_ref"]
      assert kept["materialization_state"] == "complete"
      assert {:ok, %{source: "inbound"}} = Ankole.Files.fetch(agent.uid, drive_path)
    end
  end

  defp insert_message_observation!(
         provider_message_id,
         text,
         provider_time,
         author \\ nil,
         provider_thread_id \\ "thread-1"
       ) do
    conversation_id = conversation_id!("lark:chat:group-a")
    author = author || group_entry().author
    uid = Map.get(author, :agent_uid) || Map.get(author, :principal_uid)

    author =
      case uid && Ecto.UUID.cast(uid) do
        :error ->
          kind = if Map.has_key?(author, :agent_uid), do: :agent, else: :human

          %{principal: principal} =
            if kind == :agent,
              do: agent_fixture(%{display_name: author[:display_name]}),
              else: human_fixture(%{display_name: author[:display_name]})

          Map.put(author, if(kind == :agent, do: :agent_uid, else: :principal_uid), principal.uid)

        _ ->
          author
      end

    assert {:ok, _} =
             Repo.transact(fn repo ->
               if author[:agent_uid] do
                 {:ok, _} =
                   External.observe_conversation_in_tx(
                     repo,
                     %{agent_uid: author.agent_uid},
                     %{provider_conversation_id: "lark:chat:group-a", external_kind: :im_group},
                     provider_time
                   )
               end

               External.observe_in_tx(
                 repo,
                 conversation_id,
                 %{
                   provider_message_id: provider_message_id,
                   provider_thread_id: provider_thread_id,
                   text: text,
                   author: Map.new(author, fn {key, value} -> {to_string(key), value} end),
                   provider_time: provider_time
                 },
                 provider_time
               )
             end)

    message_snapshot!(conversation_id: conversation_id, provider_message_id: provider_message_id)
  end

  defp append_retry_target!(agent_uid, binding_name, session_id) do
    unique = System.unique_integer([:positive])
    {:ok, binding} = Ankole.Signals.Bindings.get_binding(agent_uid, binding_name)

    {:ok, room} =
      Repo.transact(fn repo ->
        External.observe_conversation_in_tx(
          repo,
          binding,
          %{
            provider_conversation_id: "lark:chat:group-a",
            external_kind: :im_group,
            reply_mode: :entry
          },
          @base_time
        )
      end)

    assert {:ok, target} =
             Ankole.Signals.accept(%{
               source: "test://retry",
               authorization: Ankole.Principals.WorkAccess.service(),
               id: "retry-target-#{unique}",
               type: "cron.fire",
               subject: session_id,
               time: @base_time,
               available_at: @base_time,
               target: %{agent_uid: agent_uid, session_id: session_id},
               sender: nil,
               reply_route: %{
                 binding_name: binding_name,
                 conversation_id: room.id,
                 provider_thread_id: "target-thread-#{unique}",
                 provider_message_id: "target-source-#{unique}"
               },
               data: %{"wake_payload" => %{"schedule_id" => "schedule-#{unique}"}}
             })

    target
  end

  defp insert_durable_reply_surface!(target, binding_name, provider_provider_message_id) do
    outbound_key = "retry-surface:#{Ecto.UUID.generate()}"

    Ankole.SignalsFixtures.delivery_fixture!(%{
      agent_uid: target.agent_uid,
      binding_name: binding_name,
      outbound_key: outbound_key,
      delivery_class: :durable_ai_reply,
      operation: :card,
      status: :sent,
      conversation_id: target.conversation_id,
      created_provider_message_id: provider_provider_message_id,
      source_signal_id: target.id,
      payload: %{},
      fallback_visible_text: "retry target",
      idempotency_key: outbound_key,
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    })
  end

  defp complete_actor_response!(agent_uid, conversation_id, signal_id) do
    assert {:ok, response} =
             start_response_run(%{
               subject_uid: agent_uid,
               conversation_id: conversation_id,
               metadata: %{"request_metadata" => %{"signal_id" => signal_id}},
               request_items: [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "actor input"}]
                 }
               ]
             })

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "assistant output"}]
               }
             ])

    response
  end
end
