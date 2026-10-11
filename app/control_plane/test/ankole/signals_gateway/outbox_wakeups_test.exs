defmodule Ankole.SignalsGateway.OutboxWakeupsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Conversations.Reconciler
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Jobs.OutboxDispatch

  @now ~U[2026-10-11 00:00:00.000000Z]

  test "recovery selects due unfinished deliveries and preserves stopped rows" do
    %{principal: agent} = agent_fixture()

    due = [
      {"created", %{}},
      {"failed", %{status: :failed, attempt_count: 1, next_attempt_at: @now}},
      {"unknown", %{status: :unknown_after_send, attempt_count: 1, next_attempt_at: @now}},
      {"sending", %{status: :sending, platform_send_started_at: DateTime.add(@now, -60)}}
    ]

    skipped = [
      {"future", %{status: :failed, next_attempt_at: DateTime.add(@now, 1)}},
      {"in-flight", %{status: :sending, platform_send_started_at: DateTime.add(@now, -59)}},
      {"blocked", %{status: :failed, recovery_state: %{"state" => "blocked"}}},
      {"permanent", %{status: :failed, recovery_state: %{"state" => "permanent"}}},
      {"exhausted",
       %{status: :failed, attempt_count: 10, recovery_state: %{"state" => "exhausted"}}},
      {"stopped-unknown", %{status: :unknown_after_send}},
      {"succeeded", %{status: :succeeded}},
      {"unsupported", %{status: :unsupported}}
    ]

    rows = for {key, attrs} <- due ++ skipped, do: outbox_fixture(agent.uid, key, attrs)
    Repo.delete_all(dispatch_jobs(agent.uid))

    assert :ok = Outbox.reconcile_wakeups(@now)
    assert :ok = Outbox.reconcile_wakeups(@now)

    assert Enum.sort(Repo.all(from j in dispatch_jobs(agent.uid), select: j.args["outbound_key"])) ==
             Enum.sort(Enum.map(due, &elem(&1, 0)))

    for row <- rows do
      assert stored_outbox(row) == row
    end
  end

  test "active jobs retain their deadlines and infrastructure retry counts" do
    %{principal: agent} = agent_fixture()

    jobs =
      for state <- ["available", "scheduled", "retryable", "executing"] do
        outbox_fixture(agent.uid, state)
        job = Repo.one!(where(dispatch_jobs(agent.uid), [j], j.args["outbound_key"] == ^state))

        job
        |> change(state: state, attempt: 3, scheduled_at: DateTime.add(@now, 600))
        |> Repo.update!()
        |> Repo.reload!()
      end

    assert :ok = Outbox.reconcile_wakeups(@now)
    assert Repo.aggregate(dispatch_jobs(agent.uid), :count) == 4
    for job <- jobs, do: assert(Repo.reload!(job) == job)
  end

  test "a discarded job is replaced without resetting the outbox attempt audit" do
    %{principal: agent} = agent_fixture()

    outbox =
      outbox_fixture(agent.uid, "discarded", %{
        status: :failed,
        attempt_count: 2,
        next_attempt_at: @now
      })

    job = Repo.one!(dispatch_jobs(agent.uid))

    discarded =
      job
      |> change(state: "discarded", attempt: 5, discarded_at: @now)
      |> Repo.update!()

    assert :ok = Outbox.reconcile_wakeups(@now)
    assert :ok = Outbox.reconcile_wakeups(@now)
    assert Repo.aggregate(dispatch_jobs(agent.uid), :count) == 2
    assert Repo.reload!(discarded) == discarded
    assert stored_outbox(outbox).attempt_count == 2
    assert_enqueued(worker: OutboxDispatch, args: %{outbound_key: "discarded"})
  end

  test "site reconciliation restores both tenants including admitted suspended work", %{
    tenant: tenant
  } do
    %{principal: first} = agent_fixture()
    outbox_fixture(first.uid, "first-tenant")
    Repo.delete_all(dispatch_jobs(first.uid))
    other = create_tenant()

    second =
      Repo.with_tenant(other.id, fn ->
        %{principal: agent} = agent_fixture()
        outbox_fixture(agent.uid, "second-tenant")
        Repo.delete_all(dispatch_jobs(agent.uid))
        agent
      end)

    Repo.update!(change(other, suspended_at: @now))

    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: OutboxDispatch, args: %{agent_uid: first.uid, tenant_id: tenant.id})
    assert_enqueued(worker: OutboxDispatch, args: %{agent_uid: second.uid, tenant_id: other.id})
    assert Repo.tenant_id!() == tenant.id
  end

  defp outbox_fixture(agent_uid, key, attrs \\ %{}) do
    assert {:ok, %OutboxEntry{} = outbox} =
             Outbox.commit_outbox(
               Map.merge(
                 %{
                   agent_uid: agent_uid,
                   binding_name: "bot",
                   outbound_key: key,
                   operation: :post,
                   fallback_visible_text: "Recover the reply"
                 },
                 Map.new(attrs)
               )
             )

    outbox
  end

  defp dispatch_jobs(agent_uid) do
    from job in Oban.Job,
      where: job.worker == ^Oban.Worker.to_string(OutboxDispatch),
      where: job.args["agent_uid"] == ^agent_uid
  end

  defp stored_outbox(row) do
    Repo.get_by!(OutboxEntry,
      agent_uid: row.agent_uid,
      binding_name: row.binding_name,
      outbound_key: row.outbound_key
    )
  end
end
