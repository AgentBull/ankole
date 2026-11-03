defmodule Ankole.Signals.DispatchTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]
  alias Ankole.{AutomationJobs, Signals}
  alias Ankole.Pod.{Bases, Pages}
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Signals.{BindingReceipt, Dispatch}

  test "fanout prepares distinct Jobs in one read and rechecks their snapshots before delivery" do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "applet"})

    publish_applet_fixture(
      %{actor: actor, page: page},
      "export default {actions:{work:{handler:()=>true}}}"
    )

    jobs =
      for _ <- 1..3 do
        {:ok, job} =
          AutomationJobs.create_applet_job(actor, page.id, "work", %{
            authorization_kind: "service"
          })

        job
      end

    reference = "applet://#{page.id}"
    signal = %{"id" => "fanout", "type" => "test.changed", "data" => %{}}

    assert {{:ok, %{jobs: empty}}, 0} =
             count_reads("automation_jobs", fn -> Dispatch.prepare(reference, signal) end)

    assert empty == %{}

    for job <- [hd(jobs) | jobs] do
      {:ok, _} =
        Signals.put_event_binding(actor, %{config_ref: reference, automation_job_id: job.id})
    end

    assert {{:ok, plan}, 1} =
             count_reads("automation_jobs", fn -> Dispatch.prepare(reference, signal) end)

    assert map_size(plan.jobs) == 3
    assert length(plan.deliveries) == 4
    assert MapSet.new(Map.keys(plan.jobs)) == MapSet.new(jobs, & &1.id)

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, []} =
               AutomationJobs.list_automation_jobs(
                 query: [filter: [id: [in: Map.keys(plan.jobs)]]]
               )
    end)

    {:ok, _} =
      AutomationJobs.configure_applet_job(actor, page.id, hd(jobs).id, %{config: %{v: 2}})

    assert {:error, :binding_changed} =
             Repo.transact_top_level(fn -> Dispatch.lock_in_tx(plan) end)

    assert Ankole.Ash.read!(BindingReceipt) == []

    assert {:error, _} =
             Signals.emit(
               reference,
               Map.put(signal, "data", %{"large" => String.duplicate("x", 1_048_576)})
             )

    assert Ankole.Ash.read!(BindingReceipt) == []
    assert Ankole.Ash.read!(Run) == []

    assert {:ok, first} = Signals.emit(reference, signal)
    assert length(first.receipts) == 4
    assert {:ok, replay} = Signals.emit(reference, signal)

    assert_persisted_equal(
      Enum.sort_by(first.receipts, & &1.binding_id),
      Enum.sort_by(replay.receipts, & &1.binding_id)
    )

    runs = Ankole.Ash.read!(Run)
    assert length(runs) == 4
    assert MapSet.new(runs, & &1.automation_job_id) == MapSet.new(jobs, & &1.id)
  end

  test "receipt cleanup batches history reads without skipping expired rows or removing history" do
    %{principal: agent} = agent_fixture()
    source = Ankole.WorkFixtures.service_source(agent.uid)
    now = DateTime.utc_now(:microsecond)
    cutoff = DateTime.add(now, -7 * 86400, :second)
    expired_at = DateTime.add(cutoff, -1, :second)

    {:ok, %{scheduled_event: event}} =
      Ankole.Schedule.create_check_back_later(
        %{
          agent_uid: agent.uid,
          session_id: source.session_id,
          source_signal_id: source.id,
          tool_call_id: "receipt-history",
          idempotency_key: "receipt-history",
          schedule: %{"at" => DateTime.to_iso8601(now), "timezone" => "UTC"},
          reason: "Check the result",
          check: "Check the result",
          context_summary: "Receipt retention test"
        },
        now: DateTime.add(now, -60, :second)
      )

    assert {:ok, %{status: :fired}} = Ankole.Schedule.fire_due_event(event.id, now: now)
    [history] = Ankole.Ash.read!(BindingReceipt)
    Repo.update_all(BindingReceipt, set: [received_at: expired_at])

    # Seed the accumulated receipts around a real scheduled delivery, crossing
    # the cleanup batch boundary while retaining its historical reference.
    base = Map.take(history, [:tenant_id, :binding_id, :source])

    expired =
      for n <- 1..1000 do
        Map.merge(base, %{
          source_event_id: "zz-expired-#{String.pad_leading(to_string(n), 4, "0")}",
          signal_id: Ash.UUIDv7.generate(),
          received_at: expired_at
        })
      end

    recent =
      for {id, at} <- [{"cutoff", cutoff}, {"recent", now}] do
        Map.merge(base, %{source_event_id: id, signal_id: Ash.UUIDv7.generate(), received_at: at})
      end

    assert {1002, _} = Repo.insert_all(BindingReceipt, expired ++ recent)

    assert {{:ok, 2}, 2} =
             count_queries("signal_binding_receipts", "DELETE", fn ->
               count_reads("scheduled_events", fn -> Dispatch.expire_receipts(now) end)
             end)

    remaining = Ankole.Ash.read!(BindingReceipt)

    assert MapSet.new(remaining, & &1.source_event_id) ==
             MapSet.new([history.source_event_id, "cutoff", "recent"])

    assert [%{delivered_signal_id: delivered}] = Signals.delivery_receipts(history.signal_id)
    assert delivered == history.delivered_signal_id
    {:ok, reloaded} = Ankole.Schedule.get_checkback(event.id)

    assert [%{delivered_signal_id: ^delivered}] =
             Ankole.Schedule.Projections.event_model_projection(reloaded)["deliveries"]
  end

  test "each Binding computes its concurrency key from the rows it actually delivers" do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "applet"})
    {:ok, base} = Pages.create(actor, %{type: "base"})
    {:ok, table} = Bases.create_table(actor, base.id, %{name: "Source"})
    {:ok, address} = Bases.create_field(actor, table.id, %{name: "Address", type: "text"})
    {:ok, approval} = Bases.create_field(actor, table.id, %{name: "Approval", type: "text"})
    {:ok, _} = Bases.configure_table(actor, table.id, %{emit_changes: true})

    publish_applet_fixture(%{actor: actor, page: page}, """
    export default {actions:{work:{idempotent:true,concurrency:'serial_coalesce',
      concurrencyKey:ctx=>ctx.signal.data.changes[0].id,handler:()=>true}}}
    """)

    {:ok, job} =
      AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "service"})

    for field <- [address, approval] do
      {:ok, _} =
        Signals.put_event_binding(actor, %{
          config_ref: "base://#{table.id}",
          automation_job_id: job.id,
          watched_field_ids: [field.id]
        })
    end

    {:ok, %{records: records}} =
      Bases.write_records(actor, table.id, %{
        creates: [
          %{data: %{address.id => "A"}},
          %{data: %{approval.id => "approved"}}
        ]
      })

    assert :ok = Ankole.Pod.Bases.Outbox.drain()
    runs = Ankole.Ash.read!(Run)
    assert length(runs) == 2
    assert MapSet.new(runs, & &1.concurrency_key) == MapSet.new(records, & &1.id)

    for run <- runs do
      assert [%{"id" => id}] = run.event["data"]["changes"]
      assert run.concurrency_key == id
    end
  end

  defp count_reads(table, operation), do: count_queries(table, "SELECT", operation)

  defp count_queries(table, prefix, operation) do
    reference = make_ref()
    observer = self()

    :ok =
      :telemetry.attach(
        reference,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == observer and metadata.source == table and
               String.starts_with?(metadata.query, prefix) do
            send(observer, {reference, :read})
          end
        end,
        nil
      )

    try do
      result = operation.()
      {result, read_count(reference, 0)}
    after
      :telemetry.detach(reference)
    end
  end

  defp read_count(reference, count) do
    receive do
      {^reference, :read} -> read_count(reference, count + 1)
    after
      0 -> count
    end
  end
end
