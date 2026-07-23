defmodule Ankole.SignalsGatewayLifecycleTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.ActorRuntimeCase, only: [complete_actor_event: 4]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  describe "entry removal lifecycle" do
    test "removal before receive writes tombstone and drops late receive" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-1"}),
                 now: @base_time
               )

      assert Repo.aggregate(InputTombstone, :count) == 1

      assert {:ok, %{status: :dropped_tombstoned}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, source_event_id: "evt-late"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0
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
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
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
               Ingress.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert Repo.aggregate(ActorEvent, :count) == 0
      assert batch.batch_state == "open"

      assert {:ok, %{updated_inbound_batches: 1, canceled_actor_events: 0, lifecycle_events: []}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "recall-1"}),
                 now: @base_time
               )

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0

      assert %InboundBatch{batch_state: "canceled", outcome: "canceled", entries: entries} =
               Repo.get!(InboundBatch, batch.id)

      assert entries == []
    end

    test "removal after actor commit appends deterministic lifecycle input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_event: original_input} =
        emit_addressed_actor_event(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _consumed} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      assert {:ok, %{lifecycle_events: [lifecycle_event]}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-consumed"}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert lifecycle_event.type == "signal.entry.removed"
      assert lifecycle_event.available_at == DateTime.add(@base_time, 2, :second)
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "removal of an earlier batched entry finds the completed actor event" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      alice = %{principal_uid: "alice", id: "provider-alice", display_name: "Alice"}

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-batch-a",
                   source_entry_id: "msg-batch-a",
                   author: alice,
                   text: "first"
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :accepted}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   source_event_id: "evt-batch-b",
                   source_entry_id: "msg-batch-b",
                   author: alice,
                   text: "second"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert {:ok, [%{actor_event: original_input}]} =
               finalize_due_inbound_batch_events(
                 now: DateTime.add(@base_time, 1_200, :millisecond)
               )

      assert original_input.source_entry_id == "msg-batch-b"

      assert {:ok, _consumed} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      assert {:ok, %{lifecycle_events: [lifecycle_event]}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "delete-batch-a",
                   source_entry_id: "msg-batch-a"
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert lifecycle_event.type == "signal.entry.removed"
      assert lifecycle_event.source_entry_id == "msg-batch-a"
      assert lifecycle_event.available_at == DateTime.add(@base_time, 2, :second)
    end

    test "actor commit rejects a actor event after a committed tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_event: original_input} =
        emit_addressed_actor_event(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "recall-before-commit"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert {:error, :actor_event_not_found} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.aggregate(ActorEvent, :count) == 0
    end

    test "actor commit rejects an existing actor event row when tombstone already exists" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      %{actor_event: original_input} =
        emit_addressed_actor_event(agent.uid, "bot", group_entry(%{explicit: true}))

      assert {:ok, _tombstone} =
               %InputTombstone{}
               |> InputTombstone.changeset(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 signal_channel_id: "lark:chat:group-a",
                 source_entry_id: "msg-1",
                 tombstoned_until: DateTime.add(@base_time, 1, :day)
               })
               |> Repo.insert()

      assert {:error, :actor_event_canceled} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 original_input.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 2, :second))
               )

      assert Repo.aggregate(ActorEvent, :count) == 1
    end

    test "removal of record_only entry only updates mirror and tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(), now: @base_time)

      assert {:ok, %{canceled_actor_events: 0, lifecycle_events: []}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-record-only"}),
                 now: @base_time
               )

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0
    end

    test "removal preserves queued and running BackgroundAgentJobs and their dispatches" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :recorded}} =
               Ingress.emit_entry(agent.uid, "bot", group_entry(), now: @base_time)

      jobs =
        for suffix <- ["queued", "running"] do
          attrs = %{
            "agent_uid" => agent.uid,
            "owner_session_id" => "owner-#{suffix}",
            "source_tool_call_id" => "source-removal-#{suffix}",
            "title" => "Preserve #{suffix} Job",
            "task" => "Continue after the source entry is removed.",
            "reply_route" => %{
              "binding_name" => "bot",
              "signal_channel_id" => "lark:chat:group-a",
              "provider_thread_id" => "thread-1",
              "source_entry_id" => "msg-1"
            }
          }

          assert {:ok, %{job: job, dispatch_event: dispatch}} =
                   BackgroundAgentJobs.create_with_dispatch(attrs)

          assert dispatch.source_entry_id == nil
          {suffix, attrs, job, dispatch}
        end

      {"running", _attrs, running, _dispatch} = List.keyfind!(jobs, "running", 0)

      assert {:ok, %{job: %Job{status: "running"}}} =
               BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
                 "status" => "running"
               })

      assert {:ok, %{canceled_actor_events: 0, retried_actor_events: 0, lifecycle_events: []}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "remove-background-agent-job-source"}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      for {suffix, attrs, job, dispatch} <- jobs do
        assert %Job{status: ^suffix} = Repo.get!(Job, job.id)
        assert Repo.get!(ActorEvent, dispatch.id).id == dispatch.id

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
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "new",
                   provider_time: DateTime.add(@base_time, 10, :second)
                 }),
                 now: @base_time
               )

      assert {:ok, %{status: :mirrored}} =
               Ingress.emit_reaction(
                 agent.uid,
                 "bot",
                 %{
                   signal_channel_id: "lark:chat:group-a",
                   source_entry_id: "msg-1",
                   reaction_key: "thumbsup",
                   raw_reaction_key: "👍",
                   actor_key: "alice"
                 },
                 now: @base_time
               )

      assert {:ok, %{status: :recorded}} =
               Ingress.emit_entry(
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
        Repo.get_by!(Entry,
          signal_channel_id: "lark:chat:group-a",
          source_entry_id: "msg-1"
        )

      assert entry.text == "new"
      assert entry.reactions == %{"thumbsup" => ["alice"]}
      assert entry.raw_reaction_keys == %{"thumbsup" => "👍"}
    end

    test "unknown reactions are ignored" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:ok, %{status: :ignored_unknown_entry}} =
               Ingress.emit_reaction(
                 agent.uid,
                 "bot",
                 %{
                   signal_channel_id: "missing-channel",
                   source_entry_id: "missing-message",
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
               Ingress.emit_entry(
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
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "delete-sparse-channel",
                   channel: %{}
                 }),
                 now: DateTime.add(@base_time, 1, :second)
               )

      channel = Repo.get!(Channel, "lark:chat:group-a")

      assert channel.kind == :im_group
      assert channel.reply_mode == :entry
      assert channel.name == "Ops Room"
      assert channel.metadata == %{"topic" => "incidents"}
    end

    test "attachments must already be materialized before gateway persistence" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)

      assert {:error, {:invalid_attachment_payload, preview}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [%{provider_ref: "lark:file:file-1", runtime: self()}]
                 }),
                 now: @base_time
               )

      assert preview["runtime"]["__type__"] == "pid"
      assert Repo.aggregate(Entry, :count) == 0

      assert {:error, {:attachment_not_materialized, _attachment}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [%{file_path: "/tmp/host-only.png"}]
                 }),
                 now: @base_time
               )

      assert {:ok, %{signal_entry: entry}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   attachments: [
                     %{provider_ref: "lark:file:file-1", name: "report.pdf"},
                     %{agent_computer_path: "/agents/#{agent.uid}/user-files/report.pdf"}
                   ]
                 }),
                 now: @base_time
               )

      assert entry.attachments == [
               %{"name" => "report.pdf", "provider_ref" => "lark:file:file-1"},
               %{"agent_computer_path" => "/agents/#{agent.uid}/user-files/report.pdf"}
             ]
    end
  end

  describe "durable JSON payload validation" do
    test "entry ingress rejects runtime values before mirror or actor event writes" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:error, {:invalid_ingress_json, :metadata, :unsupported_runtime_value}} =
               Ingress.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{explicit: true, metadata: %{"pid" => self()}}),
                 now: @base_time
               )

      assert Repo.aggregate(Entry, :count) == 0
      assert Repo.aggregate(ActorEvent, :count) == 0
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
               table == "signal_gateway_entries" and column == "provider_thread_id"
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

      assert "signal_gateway_outbox_entries" in tables
      refute "actor_outbox" in tables
    end
  end
end
