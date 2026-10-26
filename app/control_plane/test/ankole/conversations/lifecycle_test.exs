defmodule Ankole.Conversations.LifecycleTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  alias Ankole.Conversations.{Attachments, Observe}
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.InputTombstone
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Message
  import Ankole.Conversations.Assertions

  import Ankole.SessionsCase, only: [complete_signal: 4]
  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  test "inbound actions own terminal state and increment the persisted revision" do
    %{principal: agent} = agent_fixture()

    conversation =
      Ankole.ExternalConversationsFixtures.external_conversation_fixture("batch-state")

    assert {:ok, batch} =
             Repo.transact(fn ->
               Ankole.Ash.create(InboundBatch, :open, %{
                 agent_uid: agent.uid,
                 binding_name: "batch-state",
                 session_id: Ankole.Sessions.Key.conversation(conversation.id),
                 conversation_id: conversation.id,
                 policy: :ignore,
                 entries: [%{"provider_message_id" => "first"}],
                 available_at: @base_time
               })
             end)

    assert batch.batch_state == :open
    assert batch.batch_revision == 0
    assert batch.provider_thread_id == ""

    for expected <- 1..3 do
      assert {:ok, revised} =
               Repo.transact(fn ->
                 Ankole.Ash.update(batch, :revise, %{
                   available_at: DateTime.add(@base_time, expected)
                 })
               end)

      assert revised.batch_revision == expected
    end

    assert {:ok, finalized} =
             Repo.transact(fn ->
               Ankole.Ash.update(Repo.reload!(batch), :finalize, %{})
             end)

    assert finalized.batch_state == :finalized
    assert finalized.batch_revision == 4

    for {action, attrs} <- [{:revise, %{entries: []}}, {:cancel, %{}}, {:finalize, %{}}] do
      assert {:error, %Ash.Error.Invalid{}} =
               Repo.transact(fn ->
                 Ankole.Ash.update(finalized, action, attrs)
               end)
    end

    Ankole.DataCase.assert_persisted_equal(Repo.reload!(finalized), finalized)

    for {action, attrs} <- [
          {:replace_prefix, %{entries: []}},
          {:revise, %{entries: []}},
          {:cancel, %{}},
          {:finalize, %{}}
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Repo.transact(fn -> Ankole.Ash.update(batch, action, attrs) end)
    end

    Ankole.DataCase.assert_persisted_equal(Repo.reload!(finalized), finalized)

    assert_raise Postgrex.Error, ~r/inbound_batches_revision_non_negative/, fn ->
      Repo.query!(
        "UPDATE conversation_inbound_batches SET batch_revision = -1 WHERE id = $1",
        [Ecto.UUID.dump!(batch.id)],
        mode: :savepoint
      )
    end

    assert Repo.reload!(finalized).batch_revision == 4
  end

  test "tombstone renewal preserves identity and expiry removal uses the persisted deadline" do
    conversation =
      Ankole.ExternalConversationsFixtures.external_conversation_fixture("tombstone-state")

    attrs = %{
      conversation_id: conversation.id,
      provider_message_id: "retracted",
      tombstoned_until: DateTime.add(@base_time, 1, :hour)
    }

    assert {:ok, first} =
             Repo.transact(fn ->
               Ankole.Ash.create(InputTombstone, :record, attrs)
             end)

    assert {:ok, renewed} =
             Repo.transact(fn ->
               Ankole.Ash.create(InputTombstone, :record, %{
                 attrs
                 | tombstoned_until: DateTime.add(@base_time, 2, :hour)
               })
             end)

    assert renewed.inserted_at == first.inserted_at
    assert Repo.aggregate(InputTombstone, :count) == 1

    assert %{tombstones: 0} =
             Ankole.Signals.StateCleanup.cleanup_expired_state(first.tombstoned_until)

    assert_persisted_equal(
      Repo.get_by!(InputTombstone,
        conversation_id: conversation.id,
        provider_message_id: "retracted"
      ),
      renewed
    )

    assert %{tombstones: 1} =
             Ankole.Signals.StateCleanup.cleanup_expired_state(renewed.tombstoned_until)

    assert Repo.aggregate(InputTombstone, :count) == 0
  end

  describe "entry removal lifecycle" do
    test "removal observed by one Agent prevents another observer from restoring the shared message" do
      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()
      binding_fixture(first.uid, "first", :ignore)
      binding_fixture(second.uid, "second", :ignore)
      binding_fixture(first.uid, "other-route", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(first.uid, "first", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(Message, :count) == 1

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry_removed(first.uid, "first", lifecycle_entry(%{}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      for {uid, name} <- [{second.uid, "second"}, {first.uid, "other-route"}] do
        assert {:ok, %{status: :dropped_tombstoned}} =
                 Observe.emit_entry(uid, name, group_entry(%{explicit: true}),
                   now: DateTime.add(@base_time, 2, :second)
                 )
      end

      assert Repo.aggregate(Message, :count) == 0
    end

    test "removal through one route fences another Agent's queued reply" do
      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()
      binding_fixture(first.uid, "first", :ignore)
      binding_fixture(second.uid, "second", :ignore)

      %{signal: input} =
        emit_addressed_signal(second.uid, "second", group_entry(%{explicit: true}))

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry_removed(
                 first.uid,
                 "first",
                 lifecycle_entry(%{}),
                 now: @base_time
               )

      assert {:error, :signal_canceled} =
               Ankole.Sessions.Queue.ensure_event_source_live_in_tx(
                 Repo.reload!(input),
                 DateTime.add(@base_time, 1, :second)
               )
    end

    test "removal before receive writes tombstone and drops late receive" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-1"}),
                 now: @base_time
               )

      assert Repo.aggregate(InputTombstone, :count) == 1

      assert {:ok, %{status: :dropped_tombstoned}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, source_event_id: "evt-late"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "removal while inbound batch is pending removes source entry without lifecycle wake" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted, inbound_batch: batch}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(Signal, :count) == 0
      assert batch.batch_state == :open

      assert {:ok, %{updated_inbound_batches: 1, canceled_signals: 0, lifecycle_events: []}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "recall-1"}),
                 now: @base_time
               )

      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0

      assert %InboundBatch{batch_state: :canceled, entries: entries} =
               Repo.get!(InboundBatch, batch.id)

      assert entries == []
    end

    test "removal after actor commit appends deterministic lifecycle input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      {:ok, %{signal: original_input}} =
        Ankole.SessionsCase.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
          now: @base_time
        )

      assert {:ok, _consumed} =
               complete_signal(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      assert {:ok, %{lifecycle_events: [lifecycle_event]}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-consumed"}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert lifecycle_event.type == "conversation.message.removed"
      lifecycle_event_id = lifecycle_event.id

      assert_enqueued(
        worker: Ankole.Sessions.Jobs.EnsureDriver,
        args: %{agent_uid: agent.uid, session_id: lifecycle_event.session_id}
      )

      assert Repo.get!(Signal, lifecycle_event_id).id == lifecycle_event_id
      assert lifecycle_event.available_at == DateTime.add(@base_time, 2, :second)
      assert Repo.aggregate(Message, :count) == 0
    end

    test "removal of an earlier batched entry finds the completed actor event" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{principal: human} = human_fixture()
      alice = provider_author_fixture(human.uid, "provider-alice", %{display_name: "Alice"})

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-batch-a",
                   provider_message_id: "msg-batch-a",
                   author: alice,
                   text: "first"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-batch-b",
                   provider_message_id: "msg-batch-b",
                   author: alice,
                   text: "second"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert {:ok, [%{signal: original_input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 1_200, :millisecond)
               )

      assert original_input.provider_message_id == "msg-batch-b"

      assert {:ok, _consumed} =
               complete_signal(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      assert {:ok, %{lifecycle_events: [lifecycle_event]}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "delete-batch-a",
                   provider_message_id: "msg-batch-a"
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert lifecycle_event.type == "conversation.message.removed"
      assert lifecycle_event.provider_message_id == "msg-batch-a"
      assert lifecycle_event.available_at == DateTime.add(@base_time, 2, :second)
    end

    test "actor commit rejects a actor event after a committed tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{signal: original_input} =
        emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "recall-before-commit"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert {:error, :signal_not_found} =
               complete_signal(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.aggregate(Signal, :count) == 0
    end

    test "actor commit rejects an existing actor event row when tombstone already exists" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{signal: original_input} =
        emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _tombstone} =
               Repo.transact(fn ->
                 Ankole.Ash.create(InputTombstone, :record, %{
                   conversation_id: conversation_id!("lark:chat:group-a"),
                   provider_message_id: "msg-1",
                   tombstoned_until: DateTime.add(@base_time, 1, :day)
                 })
               end)

      assert {:error, :signal_canceled} =
               complete_signal(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.aggregate(Signal, :count) == 1
    end

    test "source guard checks only the actual batched inputs in one tombstone query" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      %{signal: event} = emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, event} =
               Repo.transact(fn ->
                 Ankole.Ash.update(event, :revise_input, %{
                   data:
                     Map.put(event.data, "entries", [
                       %{"provider_message_id" => event.provider_message_id},
                       %{"provider_message_id" => "batch-input"}
                     ])
                 })
               end)

      assert MapSet.new(Signal.input_provider_message_ids(event)) ==
               MapSet.new([event.provider_message_id, "batch-input"])

      assert :ok = Ankole.Sessions.Queue.ensure_event_source_live_in_tx(event, @base_time)

      assert {:ok, _} =
               Repo.transact(fn ->
                 Ankole.Ash.create(InputTombstone, :record, %{
                   conversation_id: event.conversation_id,
                   provider_message_id: "batch-input",
                   tombstoned_until: DateTime.add(@base_time, 1, :day)
                 })
               end)

      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, parent ->
          if String.contains?(metadata.query, "conversation_input_tombstones"),
            do: send(parent, {:tombstone_query, metadata.query})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :signal_canceled} =
               Ankole.Sessions.Queue.ensure_event_source_live_in_tx(event, @base_time)

      assert_receive {:tombstone_query, _}
      refute_receive {:tombstone_query, _}, 50
    end

    test "removal of a quoted message does not cancel the original stimulus" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{signal: event} =
        emit_addressed_signal(agent.uid, "bot", group_entry(%{explicit: true}))

      payload =
        put_in(event.data, ["entry", "reply_to"], %{
          "resolution" => "resolved",
          "provider_message_id" => "quoted-entry",
          "text" => "Withdraw this quoted context."
        })

      assert {:ok, event} =
               Repo.transact(fn ->
                 Ankole.Ash.update(event, :revise_input, %{data: payload})
               end)

      assert Signal.provider_message_ids(event) == [event.provider_message_id]

      refute message_snapshot(
               conversation_id: event.conversation_id,
               provider_message_id: "quoted-entry"
             )

      assert {:ok, %{status: :accepted, canceled_signals: 0}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   provider_message_id: "quoted-entry",
                   source_event_id: "withdraw-quoted-entry"
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert :ok =
               Ankole.Sessions.Queue.ensure_event_source_live_in_tx(
                 event,
                 DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, _} =
               complete_signal(
                 agent.uid,
                 "bot",
                 event.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.reload!(event).completed_at
    end

    test "removal of record_only entry only updates mirror and tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(), now: @base_time)

      assert {:ok, %{canceled_signals: 0, lifecycle_events: []}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-record-only"}),
                 now: @base_time
               )

      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "removal preserves queued and running BackgroundAgentJobs and their dispatches" do
      %{principal: agent} = background_agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(agent.uid, "bot", group_entry(), now: @base_time)

      jobs =
        for suffix <- [:queued, :running] do
          attrs = %{
            "agent_uid" => agent.uid,
            "owner_session_id" => "owner-#{suffix}",
            "source_tool_call_id" => "source-removal-#{suffix}",
            "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
            "title" => "Preserve #{suffix} Job",
            "task" => "Continue after the source entry is removed.",
            "reply_route" => %{
              "binding_name" => "bot",
              "conversation_id" => conversation_id!("lark:chat:group-a"),
              "provider_thread_id" => "thread-1",
              "provider_message_id" => "msg-1"
            }
          }

          assert {:ok, %{job: job, dispatch_event: dispatch}} =
                   BackgroundAgentJobs.create_with_dispatch(attrs)

          assert dispatch.provider_message_id == nil
          {suffix, attrs, job, dispatch}
        end

      {:running, _attrs, running, _dispatch} = List.keyfind!(jobs, :running, 0)
      Repo.update!(Ecto.Changeset.change(running, status: :running, attempts: 1))

      assert {:ok, %{job: %Job{status: :running}}} =
               BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
                 "status" => "running"
               })

      assert {:ok, %{canceled_signals: 0, retried_signals: 0, lifecycle_events: []}} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "remove-background-agent-job-source"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      for {suffix, attrs, job, dispatch} <- jobs do
        assert %Job{status: ^suffix} = Repo.get!(Job, job.id)
        assert Repo.get!(Signal, dispatch.id).id == dispatch.id

        assert {:ok, %{job: replayed, dispatch_event: replayed_dispatch}} =
                 BackgroundAgentJobs.create_with_dispatch(attrs)

        assert replayed.id == job.id
        assert replayed_dispatch.id == dispatch.id
      end
    end
  end

  describe "provider mirror behavior" do
    test "older provider time does not overwrite newer mirror and reactions survive re-mirroring" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "new",
                   provider_time: DateTime.add(@base_time, 10, :second)
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :recorded}} =
               Observe.emit_reaction(
                 agent.uid,
                 "bot",
                 %{
                   provider_conversation_id: "lark:chat:group-a",
                   provider_message_id: "msg-1",
                   reaction_key: "thumbsup",
                   raw_reaction_key: "👍",
                   actor_key: "alice"
                 },
                 now: @base_time
               )

      assert {:ok, %{status: :recorded}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-old",
                   text: "old",
                   provider_time: @base_time
                 }),
                 now: DateTime.add(@base_time, 20, :second)
               )

      entry =
        message_snapshot!(
          conversation_id: conversation_id!("lark:chat:group-a"),
          provider_message_id: "msg-1"
        )

      assert entry.text == "new"
      assert entry.reactions == %{"thumbsup" => ["alice"]}
      assert entry.raw_reaction_keys == %{"thumbsup" => "👍"}
    end

    test "unknown reactions are ignored" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :ignored_unknown_entry}} =
               Observe.emit_reaction(
                 agent.uid,
                 "bot",
                 %{
                   provider_conversation_id: "missing-channel",
                   provider_message_id: "missing-message",
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
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   channel: %{
                     kind: :im_group,
                     reply_mode: :entry,
                     name: "Ops Room",
                     metadata: %{topic: "incidents"}
                   }
                 }),
                 now: @base_time
               )

      assert {:ok, _} =
               Observe.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "delete-sparse-channel",
                   channel: %{}
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      channel = Repo.get_by!(Conversation, provider_conversation_id: "lark:chat:group-a")

      assert channel.external_kind == :im_group
      assert channel.reply_mode == :entry
      assert channel.title == "Ops Room"
      assert channel.metadata == %{"topic" => "incidents"}
    end

    test "attachments reject runtime and host-only paths before gateway persistence" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:error, {:invalid_attachment_payload, preview}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [%{provider_ref: "lark:file:file-1", runtime: self()}]
                 }),
                 now: @base_time
               )

      assert preview["runtime"]["__type__"] == "pid"
      assert Repo.aggregate(Message, :count) == 0

      assert {:error, {:attachment_not_materialized, _attachment}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [%{file_path: "/tmp/host-only.png"}]
                 }),
                 now: @base_time
               )

      {:ok, stored} = Attachments.store_attachment(%{"name" => "report.pdf"}, "report")

      assert {:ok, %{message_observation: %{message: entry}}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [
                     %{provider_ref: "lark:file:file-1", name: "report.pdf"},
                     %{blob_ref: stored["blob_ref"], path: stored["path"]}
                   ]
                 }),
                 now: @base_time
               )

      assert [provider_attachment, local_attachment] = entry.attachments

      assert %{
               "attachment_id" => provider_attachment_id,
               "name" => "report.pdf",
               "provider_ref" => "lark:file:file-1"
             } = provider_attachment

      expected_path = Ankole.Files.chat_path(entry.conversation_id, stored["path"])

      assert %{
               "attachment_id" => local_attachment_id,
               "path" => ^expected_path
             } = local_attachment

      assert provider_attachment_id >= 10_000
      assert local_attachment_id > provider_attachment_id
    end
  end

  describe "durable JSON payload validation" do
    test "entry ingress rejects runtime values before mirror or actor event writes" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:error, {:invalid_ingress_json, :metadata, :unsupported_runtime_value}} =
               Observe.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, metadata: %{"pid" => self()}}),
                 now: @base_time
               )

      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "intent commit rejects non JSON-serializable payload without inserting a row" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:error, changeset} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "bad-payload",
                 operation: :post,
                 payload: %{"pid" => self()},
                 fallback_visible_text: "bad"
               })

      assert "must be JSON-serializable object" <> _ =
               errors_on(changeset).payload |> List.first()

      assert Repo.aggregate(Intent, :count) == 0
    end
  end

  describe "negative storage assertions" do
    test "gateway storage keeps only canonical thread identity and no duplicate abstractions" do
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

      assert Enum.any?(columns, fn [table, column] ->
               table == "external_message_refs" and column == "provider_thread_id"
             end)

      refute Enum.any?(columns, fn [table, column] ->
               table == "actor_inputs" and column == "canceled_at"
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
      refute "actor_input_consumptions" in tables

      assert "deliveries" in tables
      refute "actor_intent" in tables
    end
  end
end
