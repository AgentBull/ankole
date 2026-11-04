defmodule Ankole.JobSourcesPurgeTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]
  alias Ankole.{AutomationJobs, Schedule, Signals}
  alias Ankole.AutomationJobs.JobSources
  alias Ankole.Pod.Pages

  test "50 concurrent source fanouts and Page purge finish without deadlocks or orphaned work", %{
    tenant: tenant
  } do
    on_exit(fn -> Repo.with_tenant(tenant.id, fn -> cleanup_tenant!(tenant) end) end)
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "applet"})

    publish_applet_fixture(
      %{actor: actor, page: page},
      "export default { actions: { work: { idempotent: true, handler: ctx => ctx.signal.data } } }"
    )

    {:ok, first} =
      AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "human"})

    {:ok, second} =
      AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "human"})

    {:ok, cron} =
      JobSources.schedules(actor, page.id, first.id, :put, %{
        name: "race",
        schedule: %{
          kind: "every",
          every_ms: 60_000,
          anchor_at: DateTime.utc_now() |> DateTime.to_iso8601()
        },
        timezone: "Etc/UTC",
        payload: %{mode: "race"}
      })

    assert {:ok, _} =
             Signals.put_event_binding(actor, %{
               config_ref: "schedule://#{cron.id}",
               automation_job_id: second.id
             })

    {:ok, %{webhook_endpoint: endpoint}} =
      JobSources.webhooks(actor, page.id, first.id, :create, %{
        label: "purge",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    parent = self()

    tasks =
      for _ <- 1..50 do
        Task.async(fn ->
          Repo.with_tenant(tenant.id, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Schedule.fire_cron(cron.id, now: cron.next_fire_at)
            end
          end)
        end)
      end

    purge =
      Task.async(fn ->
        Repo.with_tenant(tenant.id, fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              with {:ok, _} <- Pages.delete(actor, page.id),
                   {:ok, _} <- Pages.purge(actor, page.id),
                   do: Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => page.id}})
          end
        end)
      end)

    for _ <- 1..51, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks ++ [purge], &send(&1.pid, :go))
    results = Task.await_many(tasks, 60_000)
    assert :ok = Task.await(purge, 60_000)

    assert Enum.all?(results, fn
             {:ok, _} ->
               true

             {:error, reason}
             when reason in [:binding_changed, :cron_schedule_changed, :cron_schedule_not_found] ->
               true

             _ ->
               false
           end),
           inspect(results)

    assert {:ok, nil} = AutomationJobs.get_automation_job(first.id)
    assert {:ok, nil} = AutomationJobs.get_automation_job(second.id)
    assert Signals.Webhooks.get_endpoint(endpoint.id) == nil
    assert Ankole.Schedule.Store.get_cron_schedule(cron.id) == nil
    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 0
    assert Ankole.Ash.count!(Signals.BindingReceipt) == 0
    assert Ankole.Ash.count!(Signals.Signal) == 0
  end
end
