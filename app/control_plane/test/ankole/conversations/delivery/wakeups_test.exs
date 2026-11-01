defmodule Ankole.Conversations.Delivery.WakeupsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Sessions.Reconciler
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.Jobs.Dispatch

  @now ~U[2026-10-11 00:00:00.000000Z]

  test "recovery selects due unfinished deliveries and preserves stopped rows" do
    %{principal: agent} = agent_fixture()

    due = [
      {"created", %{}},
      {"failed", %{status: :failed, attempt_count: 1, next_attempt_at: @now}},
      {"sending", %{status: :pending, platform_send_started_at: DateTime.add(@now, -60)}}
    ]

    skipped = [
      {"future", %{status: :failed, next_attempt_at: DateTime.add(@now, 1)}},
      {"in-flight", %{status: :pending, platform_send_started_at: DateTime.add(@now, -59)}},
      {"blocked",
       %{status: :failed, recovery_status: :blocked, recovery_reason: "operator_action_required"}},
      {"permanent",
       %{status: :failed, recovery_status: :permanent, recovery_reason: "permanent_failure"}},
      {"exhausted",
       %{
         status: :failed,
         attempt_count: 10,
         recovery_status: :exhausted,
         recovery_reason: "max_attempts_reached"
       }},
      {"ambiguous-failed", %{status: :failed, possible_duplicate: true, next_attempt_at: @now}},
      {"stopped-unknown", %{status: :unknown, next_attempt_at: @now}},
      {"succeeded", %{status: :sent}},
      {"unsupported",
       %{status: :failed, recovery_status: :permanent, recovery_reason: "permanent_failure"}}
    ]

    rows = for {key, attrs} <- due ++ skipped, do: intent_fixture(agent.uid, key, attrs)
    Repo.delete_all(dispatch_jobs(agent.uid))

    assert :ok = Delivery.reconcile_wakeups(@now)
    assert :ok = Delivery.reconcile_wakeups(@now)

    assert Enum.sort(Repo.all(from j in dispatch_jobs(agent.uid), select: j.args["outbound_key"])) ==
             Enum.sort(Enum.map(due, &elem(&1, 0)))

    for row <- rows do
      assert_persisted_equal(stored_intent(row), row)
    end
  end

  test "active jobs retain their deadlines and infrastructure retry counts" do
    %{principal: agent} = agent_fixture()

    jobs =
      for state <- ["available", "scheduled", "retryable", "executing"] do
        intent_fixture(agent.uid, state)
        job = Repo.one!(where(dispatch_jobs(agent.uid), [j], j.args["outbound_key"] == ^state))

        job
        |> change(state: state, attempt: 3, scheduled_at: DateTime.add(@now, 600))
        |> Repo.update!()
        |> Repo.reload!()
      end

    assert :ok = Delivery.reconcile_wakeups(@now)
    assert Repo.aggregate(dispatch_jobs(agent.uid), :count) == 4
    for job <- jobs, do: assert(Repo.reload!(job) == job)
  end

  test "a discarded job is replaced without resetting the intent attempt audit" do
    %{principal: agent} = agent_fixture()

    intent =
      intent_fixture(agent.uid, "discarded", %{
        status: :failed,
        attempt_count: 2,
        next_attempt_at: @now
      })

    job = Repo.one!(dispatch_jobs(agent.uid))

    discarded =
      job
      |> change(state: "discarded", attempt: 5, discarded_at: @now)
      |> Repo.update!()

    assert :ok = Delivery.reconcile_wakeups(@now)
    assert :ok = Delivery.reconcile_wakeups(@now)
    assert Repo.aggregate(dispatch_jobs(agent.uid), :count) == 2
    Ankole.DataCase.assert_persisted_equal(Repo.reload!(discarded), discarded)
    assert stored_intent(intent).attempt_count == 2
    assert_enqueued(worker: Dispatch, args: %{outbound_key: "discarded"})
  end

  test "site reconciliation restores both tenants including admitted suspended work", %{
    tenant: tenant
  } do
    %{principal: first} = agent_fixture()
    intent_fixture(first.uid, "first-tenant")
    Repo.delete_all(dispatch_jobs(first.uid))
    other = create_tenant()

    second =
      Repo.with_tenant(other.id, fn ->
        %{principal: agent} = agent_fixture()
        intent_fixture(agent.uid, "second-tenant")
        Repo.delete_all(dispatch_jobs(agent.uid))
        agent
      end)

    Repo.update!(change(other, suspended_at: @now))

    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: Dispatch, args: %{agent_uid: first.uid, tenant_id: tenant.id})
    assert_enqueued(worker: Dispatch, args: %{agent_uid: second.uid, tenant_id: other.id})
    assert Repo.tenant_id!() == tenant.id
  end

  defp intent_fixture(agent_uid, key, attrs \\ %{}) do
    binding =
      Ankole.SignalsFixtures.binding_fixture(agent_uid, "bot", :record_only, adapter: "mock")

    assert {:ok, %Intent{} = intent} =
             Ankole.SignalsFixtures.commit_delivery(%{
               agent_uid: agent_uid,
               binding_id: binding.id,
               binding_name: "bot",
               outbound_key: key,
               operation: :post,
               fallback_visible_text: "Recover the reply"
             })

    # Reconciliation must preserve persisted history, including old unknown
    # rows with a retry deadline that current transition actions clear.
    intent
    |> AshPostgres.DataLayer.to_ecto()
    |> change(Map.new(attrs))
    |> Repo.update!()
  end

  defp dispatch_jobs(agent_uid) do
    from job in Oban.Job,
      where: job.worker == ^Oban.Worker.to_string(Dispatch),
      where: job.args["agent_uid"] == ^agent_uid
  end

  defp stored_intent(row) do
    Repo.get_by!(Intent,
      agent_uid: row.agent_uid,
      binding_name: row.binding_name,
      outbound_key: row.outbound_key
    )
  end
end
