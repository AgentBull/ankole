defmodule Ankole.SignalsGatewayLifecycleTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  @base_time ~U[2026-06-23 08:00:00.000000Z]

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
end
