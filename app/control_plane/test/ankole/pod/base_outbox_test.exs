defmodule Ankole.Pod.BaseOutboxTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]
  alias Ankole.{AutomationJobs, Signals}
  alias Ankole.Pod.{Bases, Pages}
  alias Ankole.AutomationJobs.Schemas.Run

  test "wakeups are unique within a tenant and independent across tenants" do
    first_tenant = Repo.tenant_id!()
    second = create_tenant()
    assert {:ok, first} = Bases.Outbox.wake()
    assert {:ok, duplicate} = Bases.Outbox.wake()
    assert first.id == duplicate.id
    assert {:ok, other} = Repo.with_tenant(second.id, &Bases.Outbox.wake/0)
    assert first.id != other.id
    assert Repo.reload!(first).args == %{"tenant_id" => first_tenant}
    assert Repo.reload!(other).args == %{"tenant_id" => second.id}
  end

  for storage <- [:inline, :physical] do
    @tag storage: storage
    test "#{storage} a broken table does not block other tables and recovers in order", %{
      storage: storage
    } do
      actor = actor_fixture(human_fixture().principal.uid)
      {:ok, page} = Pages.create(actor, %{type: "applet"})

      publish_applet_fixture(%{actor: actor, page: page}, """
      export default {actions:{work:{idempotent:true,concurrency:'serial_fifo',
        concurrencyKey:ctx=>{if(ctx.job.config.reject)throw new Error('Broken subscription');return 'default'},
        handler:()=>true}}}
      """)

      {:ok, bad_job} =
        AutomationJobs.create_applet_job(actor, page.id, "work", %{
          authorization_kind: "service",
          config: %{reject: true}
        })

      {:ok, good_job} =
        AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "service"})

      {:ok, base} = Pages.create(actor, %{type: "base"})

      tables =
        for {name, job} <- [{"Broken", bad_job}, {"Healthy", good_job}] do
          {:ok, table} = Bases.create_table(actor, base.id, %{name: name})

          if storage == :physical do
            {:ok, peer} = Bases.create_table(actor, base.id, %{name: name <> " peer"})

            {:ok, _} =
              Bases.create_field(actor, table.id, %{
                name: "Link",
                type: "link",
                config: %{"table_id" => peer.id}
              })
          end

          {:ok, _} = Bases.configure_table(actor, table.id, %{emit_changes: true})

          {:ok, _} =
            Signals.put_event_binding(actor, %{
              config_ref: "base://#{table.id}",
              automation_job_id: job.id
            })

          table
        end

      [bad, good] = tables

      for _ <- 1..101 do
        assert {:ok, _} = Bases.write_records(actor, bad.id, %{creates: [%{data: %{}}]})
      end

      assert {:ok, _} = Bases.write_records(actor, good.id, %{creates: [%{data: %{}}]})
      assert {:error, {:table_failures, errors}} = Bases.Outbox.drain()
      assert Map.keys(errors) == [bad.id]
      assert [%{automation_job_id: id}] = Ankole.Ash.read!(Run)
      assert id == good_job.id

      assert {:ok, _} =
               AutomationJobs.configure_applet_job(actor, page.id, bad_job.id, %{
                 config: %{reject: false}
               })

      assert :ok = Bases.Outbox.drain()
      assert :ok = Bases.Outbox.drain()

      runs =
        Ankole.Ash.read!(Run)
        |> Enum.filter(&(&1.automation_job_id == bad_job.id))
        |> Enum.sort_by(& &1.id)

      assert length(runs) == 101
      versions = Enum.map(runs, & &1.event["data"]["data_version"])
      assert versions == Enum.sort(versions)
      assert length(Enum.uniq(versions)) == 101
    end

    @tag storage: storage
    test "#{storage} delivery continues past one batch without a periodic sweep", %{
      storage: storage
    } do
      actor = actor_fixture(human_fixture().principal.uid)
      {:ok, page} = Pages.create(actor, %{type: "applet"})

      publish_applet_fixture(
        %{actor: actor, page: page},
        "export default {actions:{work:{idempotent:true,handler:()=>true}}}"
      )

      {:ok, job} =
        AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "service"})

      {:ok, base} = Pages.create(actor, %{type: "base"})
      {:ok, table} = Bases.create_table(actor, base.id, %{name: "Events"})

      if storage == :physical do
        {:ok, peer} = Bases.create_table(actor, base.id, %{name: "Peer"})

        {:ok, _} =
          Bases.create_field(actor, table.id, %{
            name: "Link",
            type: "link",
            config: %{"table_id" => peer.id}
          })
      end

      {:ok, _} = Bases.configure_table(actor, table.id, %{emit_changes: true})

      {:ok, _} =
        Signals.put_event_binding(actor, %{
          config_ref: "base://#{table.id}",
          automation_job_id: job.id
        })

      for _ <- 1..101 do
        assert {:ok, _} = Bases.write_records(actor, table.id, %{creates: [%{data: %{}}]})
      end

      assert %{failure: 0} = Oban.drain_queue(queue: :outbox, with_recursion: true)
      assert Ankole.Ash.count!(Run) == 101
    end
  end
end
