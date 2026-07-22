defmodule Ankole.Brain.SourceWithdrawalTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import Ecto.Query, only: [from: 2]

  alias Ankole.Brain.Jobs.WithdrawSource
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Sources
  alias Ankole.Brain.SourceWithdrawal
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Ingress

  test "provider removal reverses Brain writes caused only by the recalled input" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-causal-withdrawal", :record_only)

    assert {:ok, %{signal_entry: source}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-causal-withdrawal",
               webhook_entry(%{
                 source_event_id: "brain-causal-source-event",
                 source_entry_id: "brain-causal-source-message",
                 text: "Remember RECALL_CONTEXT_OK"
               }),
               now: base_time()
             )

    assert {:ok, actor_event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent.uid,
               binding_name: "brain-causal-withdrawal",
               session_id: "brain-causal-withdrawal",
               source_event_id: "brain-causal-observed",
               signal_channel_id: source.signal_channel_id,
               source_entry_id: source.source_entry_id,
               type: "webhook.received",
               available_at: base_time(),
               payload: %{}
             })

    completed_at = DateTime.add(base_time(), 1, :second)

    assert {:ok, _completed} =
             Repo.transact(fn repo ->
               SignalsGateway.mark_actor_event_completed_in_tx(repo, actor_event, completed_at)
             end)

    {:ok, scope} = Scope.for_store(agent.uid, "shared")

    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Recalled marker",
                 type: "fact",
                 initial_body: "RECALL_CONTEXT_OK"
               },
               %{kind: :agent, uid: agent.uid},
               metadata: %{
                 "surface" => "memory_update",
                 "actor_event_id" => actor_event.id,
                 "tool_call_id" => "call-recalled-marker"
               }
             )

    assert {:ok, [source_audit]} =
             Knowledge.list_audit(scope,
               action: "create_entry",
               entry_id: entry_id,
               limit: 1
             )

    assert {:ok, %{source_withdrawal_job_id: job_id}} =
             Ingress.emit_entry_removed(
               agent.uid,
               "brain-causal-withdrawal",
               lifecycle_entry(%{
                 source_event_id: "brain-causal-recall",
                 signal_channel_id: source.signal_channel_id,
                 source_entry_id: source.source_entry_id,
                 channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"}
               }),
               now: DateTime.add(completed_at, 1, :second)
             )

    job = Repo.get!(Oban.Job, job_id)

    assert job.args == %{
             "actor_event_ids" => [actor_event.id],
             "document_id" => source.document_id
           }

    assert :ok = perform_job(WithdrawSource, job.args)
    assert {:error, :not_found} = Knowledge.open(scope, entry_id)

    assert {:ok, audits} = Knowledge.list_audit(scope, entry_id: entry_id, limit: 10)

    assert [withdrawal_audit] =
             Enum.filter(audits, &(&1.metadata["surface"] == "source_withdrawal"))

    assert withdrawal_audit.action == "delete_entry"
    assert withdrawal_audit.actor_kind == nil
    assert withdrawal_audit.actor_uid == nil
    assert withdrawal_audit.metadata["restored_audit_id"] == source_audit.id
    assert withdrawal_audit.metadata["source_actor_event_id"] == actor_event.id
    assert withdrawal_audit.metadata["source_document_id"] == source.document_id

    assert {:ok, %{restored: "delete_entry"}} =
             Knowledge.restore_audit(
               scope,
               withdrawal_audit.id,
               %{kind: :human, uid: agent.uid},
               metadata: %{"surface" => "test_recovery"}
             )

    assert {:ok, restored} = Knowledge.open(scope, entry_id, block_limit: :all)
    assert Enum.map(restored.blocks, & &1.body) == ["RECALL_CONTEXT_OK"]
  end

  test "provider removal does not reverse a Brain write from a multi-source batch" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-batch-withdrawal", :record_only)

    assert {:ok, %{signal_entry: source}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-batch-withdrawal",
               webhook_entry(%{
                 source_event_id: "brain-batch-source-event",
                 source_entry_id: "brain-batch-source-message",
                 text: "One part of a batch"
               }),
               now: base_time()
             )

    assert {:ok, actor_event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent.uid,
               binding_name: "brain-batch-withdrawal",
               session_id: "brain-batch-withdrawal",
               source_event_id: "brain-batch-observed",
               signal_channel_id: source.signal_channel_id,
               source_entry_id: source.source_entry_id,
               type: "webhook.received",
               available_at: base_time(),
               payload: %{
                 "data" => %{
                   "entries" => [
                     %{"source_entry_id" => source.source_entry_id},
                     %{"source_entry_id" => "brain-batch-independent-message"}
                   ]
                 }
               }
             })

    assert {:ok, _completed} =
             Repo.transact(fn repo ->
               SignalsGateway.mark_actor_event_completed_in_tx(
                 repo,
                 actor_event,
                 DateTime.add(base_time(), 1, :second)
               )
             end)

    {:ok, scope} = Scope.for_store(agent.uid, "shared")

    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Batch-derived marker",
                 type: "fact",
                 initial_body: "The batch as a whole caused this entry"
               },
               %{kind: :agent, uid: agent.uid},
               metadata: %{
                 "surface" => "memory_update",
                 "actor_event_id" => actor_event.id
               }
             )

    assert {:ok, %{source_withdrawal_job_id: job_id}} =
             Ingress.emit_entry_removed(
               agent.uid,
               "brain-batch-withdrawal",
               lifecycle_entry(%{
                 source_event_id: "brain-batch-recall",
                 signal_channel_id: source.signal_channel_id,
                 source_entry_id: source.source_entry_id,
                 channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"}
               }),
               now: DateTime.add(base_time(), 2, :second)
             )

    job = Repo.get!(Oban.Job, job_id)
    assert job.args["actor_event_ids"] == []
    assert :ok = perform_job(WithdrawSource, job.args)
    assert {:ok, _projection} = Knowledge.open(scope, entry_id)
  end

  test "causal withdrawal preserves an entry changed by later unrelated work" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "shared")
    actor_event_id = Ecto.UUID.generate()
    document_id = "signal-gateway-entry:causal-conflict"

    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Later-owned entry",
                 type: "fact",
                 initial_body: "Source-owned content"
               },
               %{kind: :agent, uid: agent.uid},
               metadata: %{
                 "surface" => "memory_update",
                 "actor_event_id" => actor_event_id
               }
             )

    assert {:ok, %{results: [%{entry_lock_version: 2}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: "Independent later content"
               },
               %{kind: :agent, uid: agent.uid},
               metadata: %{
                 "surface" => "memory_update",
                 "actor_event_id" => Ecto.UUID.generate()
               }
             )

    assert {:ok,
            %{
              restored_causal_update_count: 0,
              skipped_causal_update_count: 1,
              deleted_block_count: 0,
              skipped_causal_updates: [%{reason: {:audit_restore_conflict, _details}}]
            }} = SourceWithdrawal.withdraw(document_id, [actor_event_id])

    assert {:ok, projection} = Knowledge.open(scope, entry_id, block_limit: :all)

    assert Enum.map(projection.blocks, & &1.body) == [
             "Source-owned content",
             "Independent later content"
           ]
  end

  test "provider removal enqueues exact-source block withdrawal with recoverable audit" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-withdrawal", :record_only)

    assert {:ok, %{signal_entry: source}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-withdrawal",
               webhook_entry(%{
                 source_event_id: "brain-source-event",
                 source_entry_id: "brain-source-message",
                 text: "A fact that will be withdrawn"
               }),
               now: base_time()
             )

    assert {:ok, _event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent.uid,
               binding_name: "brain-withdrawal",
               session_id: "brain-withdrawal",
               source_event_id: "brain-source-observed",
               signal_channel_id: source.signal_channel_id,
               source_entry_id: source.source_entry_id,
               type: "webhook.received",
               available_at: base_time(),
               payload: %{}
             })

    {:ok, scope} = Scope.for_store(agent.uid, "shared")

    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Withdrawal Example",
                 type: "fact",
                 summary: ""
               },
               %{kind: :agent, uid: agent.uid}
             )

    cited_body = "Quoted evidence (src:#{source.document_id})"

    assert {:ok, %{results: [%{block_id: cited_block_id, entry_lock_version: 2}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: cited_body
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, %{results: [%{block_id: retained_block_id, entry_lock_version: 3}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 2,
                 body: "Independent observation without a source marker"
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, other_source} =
             Sources.capture(
               scope,
               %{
                 kind: "file",
                 title: "Independent source",
                 original_name: "independent-source.txt",
                 content: "A separate durable source"
               },
               agent.uid
             )

    assert {:ok, %{results: [%{block_id: other_cited_block_id, entry_lock_version: 4}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 3,
                 body: "A different citation src:#{other_source.document_id}"
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, %{source_withdrawal_job_id: job_id, deleted_mirror_entries: 1}} =
             Ingress.emit_entry_removed(
               agent.uid,
               "brain-withdrawal",
               lifecycle_entry(%{
                 source_event_id: "brain-source-recall",
                 signal_channel_id: source.signal_channel_id,
                 source_entry_id: "brain-source-message",
                 channel: %{kind: :webhook_endpoint, reply_mode: :none, name: "Incident hook"}
               }),
               now: DateTime.add(base_time(), 1, :second)
             )

    assert is_integer(job_id)
    assert :ok = perform_job(WithdrawSource, %{"document_id" => source.document_id})

    assert {:ok, projection} = Knowledge.open(scope, entry_id, block_limit: :all)
    assert Enum.map(projection.blocks, & &1.id) == [retained_block_id, other_cited_block_id]
    refute Enum.any?(projection.blocks, &(&1.id == cited_block_id))

    assert {:ok, audits} =
             Knowledge.list_audit(scope,
               action: "delete_block",
               entry_id: entry_id,
               limit: 10
             )

    assert [audit] = audits
    assert audit.block_id == cited_block_id
    assert audit.actor_kind == nil
    assert audit.actor_uid == nil
    assert audit.before["body"] == cited_body
    assert audit.metadata["surface"] == "source_withdrawal"
    assert audit.metadata["source_document_id"] == source.document_id

    assert {:ok, %{restored: "delete_block"}} =
             Knowledge.restore_audit(
               scope,
               audit.id,
               %{kind: :agent, uid: agent.uid},
               metadata: %{"surface" => "test_recovery"}
             )

    assert {:ok, restored} = Knowledge.open(scope, entry_id, block_limit: :all)

    assert Enum.map(restored.blocks, & &1.id) == [
             cited_block_id,
             retained_block_id,
             other_cited_block_id
           ]
  end

  test "source withdrawal enqueue is idempotent for one document" do
    document_id = "signal-gateway-entry:withdrawal-idempotence"

    assert {:ok, first} = SourceWithdrawal.enqueue(document_id)
    assert {:ok, second} = SourceWithdrawal.enqueue(document_id)

    assert second.conflict?
    assert second.id == first.id

    other_document_id = "signal-gateway-entry:withdrawal-other-source"
    assert {:ok, other} = SourceWithdrawal.enqueue(other_document_id)
    refute other.conflict?
    refute other.id == first.id

    query =
      from job in Oban.Job,
        where: fragment("?->>'document_id' = ?", job.args, ^document_id)

    assert Repo.aggregate(query, :count) == 1

    other_query =
      from job in Oban.Job,
        where: fragment("?->>'document_id' = ?", job.args, ^other_document_id)

    assert Repo.aggregate(other_query, :count) == 1
  end
end
