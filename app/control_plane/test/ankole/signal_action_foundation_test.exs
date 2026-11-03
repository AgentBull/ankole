defmodule Ankole.SignalActionFoundationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2, publish_applet_fixture: 3]
  require Ash.Query
  alias Ankole.{AutomationJobs, Signals}
  alias Ankole.Pod.{Applets, Bases, Pages}
  alias Ankole.AutomationJobs.Schemas.{Run, State}

  setup do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "applet", title: "Actions"})
    %{actor: actor, page: page}
  end

  test "serial coalescing preserves the retry head and the delayed slice fence", ctx do
    publish_applet_fixture(ctx, action_source())

    assert {:ok, job} =
             AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
               authorization_kind: "service"
             })

    bind(ctx, job)
    assert {:ok, first} = emit(ctx, "first")
    id = hd(first.receipts).automation_job_run_id
    assert {:ok, attempt} = AutomationJobs.start_applet_attempt(id, 0)
    assert attempt.run.attempt_idempotent
    assert attempt.run.last_published_revision == 1

    tails =
      for n <- 1..10 do
        {:ok, delivery} = emit(ctx, "tail-#{n}")
        hd(delivery.receipts).automation_job_run_id
      end

    assert length(Enum.uniq(tails)) == 1
    tail = hd(tails)
    refute tail == id

    assert {:ok, %{status: :queued}} =
             AutomationJobs.infrastructure_failure(
               id,
               attempt.run.attempt_id,
               :runtime_busy,
               :retry
             )

    assert {:ok, :noop} = AutomationJobs.start_applet_attempt(tail, 0)
    assert {:ok, retry} = AutomationJobs.start_applet_attempt(id, 0)
    assert retry.run.attempts == 2

    assert {:ok, _} =
             AutomationJobs.continue_applet_slice(context(job, retry.run), %{
               "delaySeconds" => 60,
               "progress" => %{"page" => 40}
             })

    assert :ok =
             Ankole.AutomationJobs.Jobs.ExecuteRun.run(%Oban.Job{
               args: %{"automation_job_run_id" => id, "expected_slice_count" => 0}
             })

    run = AutomationJobs.get_run_record(id)
    assert run.status == :queued and run.slice_count == 1 and run.attempts_in_slice == 0

    wake =
      Repo.one!(
        from(o in Oban.Job,
          where:
            fragment("?->>'automation_job_run_id'", o.args) == ^to_string(id) and
              fragment("?->>'expected_slice_count'", o.args) == "1"
        )
      )

    assert DateTime.diff(wake.scheduled_at, DateTime.utc_now()) >= 55
    assert {:ok, next} = AutomationJobs.start_applet_attempt(id, 1)

    assert {:ok, _} =
             AutomationJobs.finish_attempt(id, next.run.attempt_id, %{
               status: "succeeded",
               result: %{"done" => true}
             })

    assert {:ok, _} = AutomationJobs.start_applet_attempt(tail, 0)
  end

  test "a script's emitted event reaches its owner and an Action in one fanout", ctx do
    publish_applet_fixture(
      ctx,
      "export default {actions:{work:{idempotent:true,handler:async()=>1}}}"
    )

    {:ok, action} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    %{principal: agent} = Ankole.SessionsCase.agent_fixture()
    source = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    Ankole.FilesFixtures.drive_file_fixture(agent.uid, "automation/fanout/main.ts")

    {:ok, script} =
      AutomationJobs.create_job(%{
        agent_uid: agent.uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        source_provenance: %{},
        drive_prefix: "automation/fanout",
        label: "Emitter",
        authorization_kind: "service",
        reply_route: %{
          "binding_name" => source.reply_binding_name,
          "conversation_id" => source.conversation_id
        }
      })

    agent_actor = actor_fixture(agent.uid)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: agent.uid, role: "contribute"}]
      })

    {:ok, binding} =
      Signals.put_event_binding(agent_actor, %{
        config_ref: "job://#{script.id}",
        automation_job_id: action.id
      })

    {:ok, %{automation_job_run: queued}} =
      Repo.transact(fn ->
        Ankole.WorkFixtures.dispatch_job_in_tx(script, %{
          "id" => "start",
          "source" => "test",
          "type" => "test",
          "data" => %{}
        })
      end)

    {:ok, _} =
      Ankole.SessionsCase.admit_worker("emit-foundation-#{agent.uid}", %{worker_id: agent.uid})

    {:ok, %{run: running}} = AutomationJobs.start_attempt(queued.id)

    assert {:ok, emitted} =
             AutomationJobs.emit_event(agent.uid, running.id, running.attempt_id, %{
               "changed" => true
             })

    assert emitted.session_id == source.session_id
    assert emitted.source == "ankole:job:#{script.id}"

    [receipt] =
      Ankole.Ash.read!(Ash.Query.filter(Signals.BindingReceipt, binding_id == ^binding.id))

    run = AutomationJobs.get_run_record(receipt.automation_job_run_id)
    assert run.automation_job_id == action.id
    assert run.event["source"] == emitted.source
    assert run.event["data"]["payload"] == %{"changed" => true}
  end

  test "a revoked personal subscription does not block the other targets of its source", ctx do
    publish_applet_fixture(ctx, action_source())
    human = human_fixture().principal

    Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
      grants: [%{principal_uid: human.uid, role: "edit"}]
    })

    {:ok, personal} =
      AutomationJobs.create_applet_job(actor_fixture(human.uid), ctx.page.id, "work", %{
        authorization_kind: "human"
      })

    {:ok, team} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    for {job, actor} <- [{personal, actor_fixture(human.uid)}, {team, ctx.actor}] do
      {:ok, _} =
        Signals.put_event_binding(actor, %{
          config_ref: "applet://#{ctx.page.id}",
          automation_job_id: job.id
        })
    end

    Ankole.PrincipalsFixtures.disable_principal_fixture(human.uid)
    assert {:ok, %{receipts: [receipt]}} = emit(ctx, "after-revocation")

    assert AutomationJobs.get_run_record(receipt.automation_job_run_id).automation_job_id ==
             team.id

    {:ok, _} =
      Repo.transact(fn ->
        Ankole.Ash.update(AutomationJobs.lock_job_in_tx(personal.id), :cancel, %{
          cancelled_at: DateTime.utc_now()
        })
      end)

    assert {:ok, %{receipts: [_]}} = emit(ctx, "after-cancellation")
  end

  test "Action events use the emitting Job's source and reject a completed attempt", ctx do
    publish_applet_fixture(ctx, """
    export default {actions:{
      work:{idempotent:true,handler:()=>AnkoleRuntime.admin.signals.emit({id:'order-123',subject:'orders',type:'chain.changed',data:{count:1}})},
      consume:{idempotent:true,handler:()=>1}
    }}
    """)

    {:ok, sink} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "consume", %{
        authorization_kind: "service"
      })

    {:ok, source} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, source)

    {:ok, binding} =
      Signals.put_event_binding(ctx.actor, %{
        config_ref: "job://#{source.id}",
        filters: %{cel: "signal.subject == 'orders'"},
        automation_job_id: sink.id
      })

    {:ok, triggered} = emit(ctx, "chain-start")
    id = hd(triggered.receipts).automation_job_run_id
    {:ok, attempt} = AutomationJobs.start_applet_attempt(id, 0)

    assert {:completed, %{"status" => 200, "body" => result}} =
             AutomationJobs.execute_applet_attempt(attempt)

    assert result["accepted"]

    [receipt] =
      Ankole.Ash.read!(Ash.Query.filter(Signals.BindingReceipt, binding_id == ^binding.id))

    child = AutomationJobs.get_run_record(receipt.automation_job_run_id)
    assert child.event["source"] == "ankole:job:#{source.id}"
    assert child.event["data"] == %{"count" => 1}
    assert child.event["id"] == "order-123"
    assert child.event["subject"] == "orders"

    assert {:ok, _} =
             AutomationJobs.infrastructure_failure(id, attempt.run.attempt_id, :lost_ack, :retry)

    assert {:ok, replay} = AutomationJobs.start_applet_attempt(id, 0)

    assert {:completed, %{"status" => 200, "body" => ^result}} =
             AutomationJobs.execute_applet_attempt(replay)

    attempt = replay
    assert child.causation_id == attempt.run.signal_id
    {:ok, _} = AutomationJobs.finish_attempt(id, attempt.run.attempt_id, %{status: "succeeded"})

    actor = %{
      ctx.actor
      | turn_authority:
          AutomationJobs.applet_attempt_authority(
            context(source, attempt.run),
            ctx.actor.principal.uid
          )
    }

    assert {:error, :automation_job_attempt_not_active} =
             Signals.applet_dispatch(
               context(source, attempt.run),
               ctx.page,
               actor,
               actor,
               "emit",
               [
                 %{"type" => "stale", "subject" => "orders"}
               ]
             )

    assert Ankole.Ash.count!(Ash.Query.filter(Signals.BindingReceipt, binding_id == ^binding.id)) ==
             1
  end

  test "Applet emissions retain the original work authorization through admin calls", ctx do
    personal = actor_fixture(human_fixture().principal.uid)
    %{principal: agent} = agent_fixture(owner_principal_uid: personal.principal.uid)
    Ankole.ConversationsFixtures.grant_chat(personal.principal.uid, agent.uid)
    source = Ankole.WorkFixtures.service_source(agent.uid)

    publish_applet_fixture(ctx, """
    const emit=()=>AnkoleRuntime.admin.signals.emit({type:'authority.changed'});
    export default {routes:{'POST /':emit}, actions:{work:{handler:emit}}}
    """)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
        grants: [%{principal_uid: personal.principal.uid, role: "edit"}]
      })

    refs =
      for kind <- ["human", "service"] do
        {:ok, job} =
          AutomationJobs.create_applet_job(personal, ctx.page.id, "work", %{
            authorization_kind: kind
          })

        {:ok, binding} =
          Signals.put_event_binding(personal, %{
            config_ref: "job://#{job.id}",
            agent_uid: agent.uid,
            target: %{session_id: source.session_id}
          })

        {:ok, %{automation_job_run: run}} =
          Repo.transact_top_level(fn ->
            AutomationJobs.enqueue_locked_in_tx(AutomationJobs.lock_job_in_tx(job.id), %{}, [])
          end)

        assert :ok =
                 Ankole.AutomationJobs.Jobs.ExecuteRun.run(%Oban.Job{
                   args: %{"automation_job_run_id" => run.id, "expected_slice_count" => 0},
                   attempt: 1,
                   max_attempts: 5
                 })

        assert AutomationJobs.get_run_record(run.id).status == :succeeded

        [receipt] =
          Ankole.Ash.read!(Ash.Query.filter(Signals.BindingReceipt, binding_id == ^binding.id))

        signal =
          Ankole.Ash.read_one!(
            Ash.Query.filter(Signals.Signal, id == ^receipt.delivered_signal_id)
          )

        assert signal.authorization_kind == kind
        assert signal.human_uid == if(kind == "human", do: personal.principal.uid)
        {kind, signal.id}
      end

    {:ok, binding} =
      Signals.put_event_binding(personal, %{
        config_ref: "applet://#{ctx.page.id}",
        agent_uid: agent.uid,
        target: %{session_id: source.session_id}
      })

    assert {:ok, %{"status" => 200}} =
             Applets.call(personal, ctx.page.id, %{
               "method" => "POST",
               "path" => "/",
               "query" => %{}
             })

    [receipt] =
      Ankole.Ash.read!(Ash.Query.filter(Signals.BindingReceipt, binding_id == ^binding.id))

    interactive =
      Ankole.Ash.read_one!(Ash.Query.filter(Signals.Signal, id == ^receipt.delivered_signal_id))

    assert interactive.human_uid == personal.principal.uid

    assert {:ok, disabled} = disable_principal_fixture(personal.principal.uid)
    cleanup = %{"human_uid" => disabled.uid, "version" => disabled.access_version}
    assert_enqueued(worker: Ankole.Principals.WorkCleanup, args: cleanup)
    assert :ok = perform_job(Ankole.Principals.WorkCleanup, cleanup)

    assert {:error, %{code: "human_access_revoked"}} =
             Ankole.Pod.Applets.Capabilities.call(
               %{"applet" => %{"pageId" => ctx.page.id}, "method" => "POST"},
               personal,
               "admin.signals.emit",
               [%{"type" => "after.revocation"}]
             )

    for {kind, id} <- [{"human", interactive.id} | refs] do
      signal = Ankole.Ash.read_one!(Ash.Query.filter(Signals.Signal, id == ^id))
      assert signal.status == if(kind == "human", do: :dead_letter, else: :queued)
    end
  end

  test "expired attempts use their admitted policy and unblock a non-idempotent head", ctx do
    publish_applet_fixture(ctx, action_source(false))

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, job)
    {:ok, first} = emit(ctx, "first")
    id = hd(first.receipts).automation_job_run_id
    {:ok, attempt} = AutomationJobs.start_applet_attempt(id, 0)
    {:ok, tail} = emit(ctx, "tail")
    publish_applet_fixture(ctx, action_source(true), 1)

    assert :ok =
             AutomationJobs.expire_attempts(now: DateTime.add(attempt.run.attempt_deadline_at, 1))

    assert AutomationJobs.get_run_record(id).status == :failed
    assert AutomationJobs.get_run_record(id).error =~ "execution_outcome_unknown"

    assert {:ok, _} =
             AutomationJobs.start_applet_attempt(hd(tail.receipts).automation_job_run_id, 0)
  end

  test "state survives an unavailable Action and a later publish resumes with current policy",
       ctx do
    publish_applet_fixture(ctx, action_source())

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, job)
    {:ok, first} = emit(ctx, "first")
    id = hd(first.receipts).automation_job_run_id
    {:ok, attempt} = AutomationJobs.start_applet_attempt(id, 0)
    c = context(job, attempt.run)
    assert {:ok, nil} = AutomationJobs.applet_state(c, "set", ["rebuild", "nullable", nil])
    assert {:ok, nil} = AutomationJobs.applet_state(c, "get", ["rebuild", "nullable"])

    assert {:error, :state_too_large} =
             AutomationJobs.applet_state(c, "set", [
               "rebuild",
               "huge",
               String.duplicate("x", 65536)
             ])

    assert {:error, :invalid_state_key} = AutomationJobs.applet_state(c, "get", ["", "page"])
    assert {:ok, nil} = AutomationJobs.applet_state(c, "set", ["rebuild", "page", 40])
    assert {:ok, _} = AutomationJobs.continue_applet_slice(c, %{})
    publish_applet_fixture(ctx, "export default {routes:{},actions:{}}", 1)
    assert {:ok, :noop} = AutomationJobs.start_applet_attempt(id, 1)
    assert AutomationJobs.get_run_record(id).error == "missing_action_key"

    assert Ankole.Ash.read_one!(
             Ash.Query.filter(State, automation_job_id == ^job.id and state_key == "page")
           ).value == 40

    publish_applet_fixture(ctx, action_source(true, 9), 2)

    assert {:ok, %{max_slices: 9, unavailable_reason: nil}} =
             AutomationJobs.get_automation_job(job.id)

    {:ok, second} = emit(ctx, "resume")

    assert {:ok, resumed} =
             AutomationJobs.start_applet_attempt(hd(second.receipts).automation_job_run_id, 0)

    assert resumed.run.last_published_revision == 3

    assert {:ok, 40} =
             AutomationJobs.applet_state(context(job, resumed.run), "get", ["rebuild", "page"])
  end

  test "service Actions reject user capabilities and nested GET calls remain read-only", ctx do
    publish_applet_fixture(ctx, """
    export default {routes:{'GET /nested':()=>AnkoleRuntime.signals.call({actionKey:'write'})},actions:{
      write:{idempotent:true,handler:async ctx=>ctx.state.set('x',1)},
      work:{idempotent:true,handler:async()=>AnkoleRuntime.file.list('#{ctx.page.id}')}
    }}
    """)

    assert {:ok, %{"status" => 500, "body" => %{"error" => %{"code" => "read_only_route"}}}} =
             Applets.call(ctx.actor, ctx.page.id, %{
               "method" => "GET",
               "path" => "/nested",
               "query" => %{}
             })

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, job)
    {:ok, first} = emit(ctx, "service")

    {:ok, attempt} =
      AutomationJobs.start_applet_attempt(hd(first.receipts).automation_job_run_id, 0)

    assert {:completed, %{"body" => %{"error" => %{"code" => "user_authority_unavailable"}}}} =
             AutomationJobs.execute_applet_attempt(attempt)
  end

  test "Base upserts, no-op writes, unique lifecycle and per-row change filtering", ctx do
    {:ok, page} = Pages.create(ctx.actor, %{type: "base", title: "Ledger"})
    {:ok, table} = Bases.create_table(ctx.actor, page.id, %{name: "Ledger"})
    {:ok, key} = Bases.create_field(ctx.actor, table.id, %{name: "Business key", type: "text"})
    {:ok, field} = Bases.create_field(ctx.actor, table.id, %{name: "State", type: "text"})

    assert {:ok, _} =
             Bases.configure_table(ctx.actor, table.id, %{
               unique_field_ids: [key.id],
               emit_changes: true
             })

    assert {:ok, first} =
             Bases.write_records(ctx.actor, table.id, %{
               upserts: [%{data: %{key.id => "A", field.id => "pending"}}]
             })

    [record] = first.records

    assert {:ok, same} =
             Bases.write_records(ctx.actor, table.id, %{
               upserts: [%{data: %{key.id => "A", field.id => "pending"}}]
             })

    assert same.data_version == first.data_version
    assert hd(same.records).versions == record.versions
    assert Ankole.Ash.count!(Ankole.Pod.Bases.ChangeOutbox) == 1

    assert {:error, :invalid_upsert_unique_key} =
             Bases.write_records(ctx.actor, table.id, %{upserts: [%{data: %{key.id => nil}}]})

    assert {:error, :duplicate_unique_key} =
             Bases.write_records(ctx.actor, table.id, %{creates: [%{data: %{key.id => "A"}}]})

    assert {:error, :unique_field_referenced} =
             Bases.update_field(ctx.actor, key.id, %{version: key.version, type: "number"})

    publish_applet_fixture(ctx, action_source())

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    assert {:ok, _} =
             Signals.put_event_binding(ctx.actor, %{
               config_ref: "base://#{table.id}",
               automation_job_id: job.id,
               watched_field_ids: [field.id]
             })

    assert :ok = Ankole.Pod.Bases.Outbox.drain()
    [run] = Run |> Ankole.Ash.read!()
    assert [%{"id" => id, "fields" => fields}] = run.event["data"]["changes"]
    assert id == record.id and field.id in fields
    assert Ankole.Ash.count!(Ankole.Pod.Bases.ChangeOutbox) == 0

    assert {:ok, _} =
             Bases.write_records(ctx.actor, table.id, %{
               deletes: [%{id: record.id, expected_versions: record.versions}]
             })

    [outbox] = Ankole.Ash.read!(Ankole.Pod.Bases.ChangeOutbox)
    assert [%{"unique_key" => unique}] = outbox.changes
    assert unique == %{key.id => "A"}
  end

  test "one hundred real Base pages resume at page forty and run current code", ctx do
    {:ok, base} = Pages.create(ctx.actor, %{type: "base"})
    {:ok, source} = Bases.create_table(ctx.actor, base.id, %{name: "Source"})
    {:ok, target} = Bases.create_table(ctx.actor, base.id, %{name: "Target"})
    source_key = Enum.find(Bases.fields(source.id), & &1.is_primary).id
    target_key = Enum.find(Bases.fields(target.id), & &1.is_primary).id

    assert {:ok, _} =
             Bases.configure_table(ctx.actor, target.id, %{unique_field_ids: [target_key]})

    assert {:ok, _} =
             Bases.write_records(ctx.actor, source.id, %{
               creates: for(n <- 1..100, do: %{data: %{source_key => "row-#{n}"}})
             })

    code = """
    export default {actions:{work:{idempotent:true,concurrency:'serial_coalesce',maxSlices:10,handler:async ctx=>{
      const s=ctx.state.scope('rebuild'); let token=await s.get('token'); let count=await s.get('count')||0;
      for(let i=0;i<40;i++) {
        const page=await AnkoleRuntime.admin.base.query('#{source.id}', {page_token:token||undefined,page_size:1});
        await AnkoleRuntime.admin.base.write('#{target.id}',{upserts:page.records.map(r=>({data:{'#{target_key}':r.data['#{source_key}']}}))});
        count+=page.records.length; await s.set('count',count);
        if(page.complete){await s.delete('token');return {count,revision:ctx.applet.revision}}
        token=page.page_token;await s.set('token',token);
      }
      return ctx.continueSlice({progress:{count}})
    }}}}
    """

    publish_applet_fixture(ctx, code)

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, job)
    {:ok, first} = emit(ctx, "initial")
    id = hd(first.receipts).automation_job_run_id
    assert :ok = execute(id, 0)
    assert AutomationJobs.get_run_record(id).progress == %{"count" => 40}
    publish_applet_fixture(ctx, "export default {actions:{}}", 1)
    assert :ok = execute(id, 1)
    assert AutomationJobs.get_run_record(id).error == "missing_action_key"
    publish_applet_fixture(ctx, code, 2)
    {:ok, resumed} = emit(ctx, "resume")
    next = hd(resumed.receipts).automation_job_run_id
    assert :ok = execute(next, 0)
    assert AutomationJobs.get_run_record(next).progress == %{"count" => 80}
    assert :ok = execute(next, 1)

    assert %{status: :succeeded, result: %{"count" => 100, "revision" => 3}} =
             AutomationJobs.get_run_record(next)

    assert {:ok, %{records: records, complete: true}} =
             Bases.query(ctx.actor, target.id, %{page_size: 200})

    assert length(records) == 100
  end

  test "unique keys survive physical promotion and native upserts preserve no-op metadata", ctx do
    {:ok, page} = Pages.create(ctx.actor, %{type: "base"})
    {:ok, table} = Bases.create_table(ctx.actor, page.id, %{name: "Physical"})
    key = Enum.find(Bases.fields(table.id), & &1.is_primary)
    {:ok, value} = Bases.create_field(ctx.actor, table.id, %{name: "Value", type: "number"})

    {:ok, _} =
      Bases.write_records(ctx.actor, table.id, %{
        creates: [%{data: %{key.id => "A"}}, %{data: %{key.id => "A"}}]
      })

    assert {:error, :duplicate_unique_key} =
             Bases.configure_table(ctx.actor, table.id, %{unique_field_ids: [key.id]})

    {:ok, other} = Bases.create_table(ctx.actor, page.id, %{name: "Promoted"})
    key = Enum.find(Bases.fields(other.id), & &1.is_primary)
    {:ok, field} = Bases.create_field(ctx.actor, other.id, %{name: "Value", type: "number"})

    {:ok, _} =
      Bases.configure_table(ctx.actor, other.id, %{unique_field_ids: [key.id], emit_changes: true})

    {:ok, %{records: [original]}} =
      Bases.write_records(ctx.actor, other.id, %{
        upserts: [%{data: %{key.id => "A", field.id => 1}}]
      })

    assert {:ok, _} =
             Bases.create_field(ctx.actor, other.id, %{
               name: "Link",
               type: "link",
               config: %{"table_id" => table.id}
             })

    assert {:ok, %{table: %{storage_mode: :physical}}} = Bases.get_table(ctx.actor, other.id)

    assert {:ok, changed} =
             Bases.write_records(ctx.actor, other.id, %{
               upserts: [%{data: %{key.id => "A", field.id => 2}}]
             })

    assert hd(changed.records).id == original.id

    assert {:ok, same} =
             Bases.write_records(ctx.actor, other.id, %{
               upserts: [%{data: %{key.id => "A", field.id => 2}}]
             })

    assert same.data_version == changed.data_version
    assert hd(same.records).updated_at == hd(changed.records).updated_at

    assert {:error, :duplicate_unique_key} =
             Bases.write_records(ctx.actor, other.id, %{creates: [%{data: %{key.id => "A"}}]})

    assert :ok = Ankole.Pod.Bases.Outbox.drain()
    assert value.type == :number
  end

  test "admin writes use the current owner while personal Run access stays with its human", ctx do
    {:ok, private} = Pages.create(ctx.actor, %{private_owner_uid: ctx.actor.principal.uid})
    {:ok, base} = Pages.create(ctx.actor, %{type: "base", parent_id: private.id})
    {:ok, table} = Bases.create_table(ctx.actor, base.id, %{name: "Requests"})
    field = Enum.find(Bases.fields(table.id), & &1.is_primary).id
    viewer = actor_fixture(human_fixture().principal.uid)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
        grants: [%{principal_uid: viewer.principal.uid, role: "contribute"}]
      })

    assert {:error, :forbidden} =
             Bases.write_records(viewer, table.id, %{creates: [%{data: %{field => "blocked"}}]})

    publish_applet_fixture(ctx, """
    export default {routes:{'POST /submit':async(req,ctx)=>{
      const result=await AnkoleRuntime.admin.base.write('#{table.id}',{creates:[{data:{'#{field}':ctx.principal.uid}}]});
      return {status:201,body:result}
    }},actions:{work:{idempotent:true,handler:async()=>1}}}
    """)

    assert {:ok, %{"status" => 201}} =
             Applets.call(viewer, ctx.page.id, %{
               "method" => "POST",
               "path" => "/submit",
               "query" => %{}
             })

    assert {:ok, %{records: [record]}} = Bases.query(ctx.actor, table.id, %{})
    assert record["created_by"] == to_string(Ankole.ActorRef.from_principal(ctx.actor.principal))

    {:ok, job} =
      AutomationJobs.create_applet_job(viewer, ctx.page.id, "work", %{authorization_kind: "human"})

    request = %{"targetJobId" => job.id, "type" => "manual"}
    context = %{"applet" => %{"pageId" => ctx.page.id}}

    assert {:ok, %{runId: id}} =
             Signals.applet_dispatch(context, ctx.page, viewer, viewer, "emit", [request])

    assert {:error, :forbidden} = AutomationJobs.get_applet_run(ctx.actor, ctx.page.id, id)
    assert {:ok, _} = AutomationJobs.get_applet_run(viewer, ctx.page.id, id)
    {:ok, other} = Pages.create(viewer, %{type: "applet"})

    assert {:error, :forbidden} =
             Signals.applet_dispatch(context, other, viewer, viewer, "emit", [request])

    {:ok, attempt} = AutomationJobs.start_applet_attempt(id, 0)
    {:ok, _} = disable_principal_fixture(viewer.principal.uid)

    actor = %{
      viewer
      | turn_authority:
          AutomationJobs.applet_attempt_authority(context(job, attempt.run), viewer.principal.uid)
    }

    assert {:error, %{code: "forbidden"}} =
             Ankole.Pod.Applets.Capabilities.call(
               Map.put(context(job, attempt.run), "applet", %{"pageId" => ctx.page.id}),
               actor,
               "file.list",
               [ctx.page.id]
             )
  end

  test "an idempotent fifth Oban attempt recovers after discard using its admitted policy", ctx do
    publish_applet_fixture(ctx, action_source())

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, job)
    {:ok, delivery} = emit(ctx, "crash")
    id = hd(delivery.receipts).automation_job_run_id

    for _ <- 1..4 do
      {:ok, attempt} = AutomationJobs.start_applet_attempt(id, 0)

      {:ok, _} =
        AutomationJobs.infrastructure_failure(id, attempt.run.attempt_id, :runtime_busy, :retry)
    end

    {:ok, fifth} = AutomationJobs.start_applet_attempt(id, 0)
    assert fifth.run.attempts_in_slice == 5

    Repo.update_all(
      from(o in Oban.Job,
        where: fragment("?->>'automation_job_run_id'", o.args) == ^to_string(id)
      ),
      set: [state: "discarded", attempt: 5]
    )

    publish_applet_fixture(ctx, action_source(false), 1)

    assert :ok =
             AutomationJobs.expire_attempts(now: DateTime.add(fifth.run.attempt_deadline_at, 1))

    assert %{status: :queued} = AutomationJobs.get_run_record(id)

    assert_enqueued(
      worker: Ankole.AutomationJobs.Jobs.ExecuteRun,
      args: %{automation_job_run_id: id, expected_slice_count: 0}
    )
  end

  @tag sandbox: false
  test "fifty concurrent fanouts, Cron and page purge leave no orphan work", ctx do
    publish_applet_fixture(
      ctx,
      "export default {actions:{work:{idempotent:true,handler:async()=>1}}}"
    )

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    bind(ctx, job)
    agent = Ankole.SessionsCase.agent_fixture().principal
    source = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    now = DateTime.utc_now(:microsecond)
    due = DateTime.add(now, 60)

    {:ok, %{cron_schedule: cron}} =
      Ankole.Schedule.create_cron_schedule(
        %{
          agent_uid: agent.uid,
          owner_session_id: source.session_id,
          binding_name: source.reply_binding_name,
          name: "Concurrent Action",
          schedule: %{
            "kind" => "every",
            "every_ms" => 60_000,
            "anchor_at" => DateTime.to_iso8601(due)
          },
          payload: %{"task" => "sync"},
          delivery: %{
            "targets" => [
              %{
                "binding_name" => source.reply_binding_name,
                "conversation_id" => source.conversation_id,
                "provider_thread_id" => source.provider_thread_id
              }
            ]
          },
          idempotency_key: "foundation-race"
        },
        now: now,
        authorization: Ankole.Principals.WorkAccess.from_sender(ctx.actor.principal.uid)
      )

    assert {:ok, _} =
             Signals.put_event_binding(ctx.actor, %{
               config_ref: "schedule://#{cron.id}",
               automation_job_id: job.id
             })

    parent = self()

    tasks =
      for n <- 1..50,
          do:
            Task.async(
              Repo.bind_tenant(fn ->
                send(parent, {:ready, self()})

                receive do
                  :go -> emit(ctx, "race-#{n}")
                end
              end)
            )

    cron_task =
      Task.async(
        Repo.bind_tenant(fn ->
          receive do
            :go -> Ankole.Schedule.fire_cron(cron.id, now: due)
          end
        end)
      )

    for _ <- tasks, do: assert_receive({:ready, _}, 5000)
    for task <- [cron_task | tasks], do: send(task.pid, :go)
    assert {:ok, _} = Pages.delete(ctx.actor, ctx.page.id)
    assert {:ok, _} = Pages.purge(ctx.actor, ctx.page.id)

    purge =
      Task.async(
        Repo.bind_tenant(fn ->
          Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => ctx.page.id}})
        end)
      )

    for task <- [cron_task | tasks] do
      case Task.await(task, 30_000) do
        {:ok, _} -> :ok
        {:error, :binding_changed} -> :ok
      end
    end

    assert :ok = Task.await(purge, 30_000)
    assert {:ok, _} = Ankole.Schedule.fire_cron(cron.id, now: due)
    assert length(Ankole.Schedule.list_cron_runs(cron.id)) == 1
    assert {:ok, nil} = AutomationJobs.get_automation_job(job.id)
    assert Ankole.Ash.count!(Ash.Query.filter(Run, automation_job_id == ^job.id)) == 0
    assert Ankole.Ash.count!(Ash.Query.filter(Signals.Binding, automation_job_id == ^job.id)) == 0
    assert {:error, :not_found} = Pages.fetch(ctx.page.id)
  end

  @tag sandbox: false
  test "concurrent upserts match one native unique key before and after promotion", ctx do
    {:ok, page} = Pages.create(ctx.actor, %{type: "base"})
    {:ok, table} = Bases.create_table(ctx.actor, page.id, %{name: "Race"})
    key = Enum.find(Bases.fields(table.id), & &1.is_primary).id
    {:ok, _} = Bases.configure_table(ctx.actor, table.id, %{unique_field_ids: [key]})

    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, table.id, %{
                   name: "Self",
                   type: "link",
                   config: %{"table_id" => table.id}
                 })
      end

      results =
        for _ <- 1..20,
            do:
              Task.async(
                Repo.bind_tenant(fn ->
                  Bases.write_records(ctx.actor, table.id, %{upserts: [%{data: %{key => "one"}}]})
                end)
              )

      ids =
        Enum.map(results, fn task ->
          assert {:ok, %{records: [record]}} = Task.await(task, 30_000)
          record.id
        end)

      assert length(Enum.uniq(ids)) == 1
      assert {:ok, %{records: records}} = Bases.query(ctx.actor, table.id, %{})
      assert length(records) == 1
    end
  end

  @tag timeout: 120_000
  test "link deletion emits bounded summaries for every changed peer beyond the UI resync limit",
       ctx do
    {:ok, page} = Pages.create(ctx.actor, %{type: "base", title: "Linked events"})
    {:ok, target} = Bases.create_table(ctx.actor, page.id, %{name: "Target"})
    {:ok, peers} = Bases.create_table(ctx.actor, page.id, %{name: "Peers"})

    {:ok, link} =
      Bases.create_field(ctx.actor, peers.id, %{
        name: "Target",
        type: "link",
        config: %{"table_id" => target.id}
      })

    {:ok, %{records: [row]}} =
      Bases.write_records(ctx.actor, target.id, %{creates: [%{data: %{}}]})

    count = Bases.max_links_per_field() + 1

    for batch <- Enum.chunk_every(1..count, 200) do
      assert {:ok, _} =
               Bases.write_records(ctx.actor, peers.id, %{
                 creates: Enum.map(batch, fn _ -> %{data: %{link.id => [row.id]}} end)
               })
    end

    {:ok, _} = Bases.configure_table(ctx.actor, peers.id, %{emit_changes: true})

    assert {:ok, _} =
             Bases.write_records(ctx.actor, target.id, %{
               deletes: [%{id: row.id, expected_versions: row.versions}]
             })

    entries =
      Ankole.Pod.BaseRepo.with_shard(Ankole.Pod.BaseRepo.shard!(), fn ->
        Ankole.Pod.Bases.Physical.pending_changes()
      end)

    entries = Enum.filter(entries, &(&1.table_id == peers.id))
    assert Enum.all?(entries, &(length(&1.changes) <= 200))
    changes = Enum.flat_map(entries, & &1.changes)
    assert length(Enum.uniq_by(changes, & &1["id"])) == count
    assert Enum.all?(changes, &(&1["fields"] == [link.id] and &1["op"] == "update"))
  end

  defp execute(id, slice),
    do:
      Ankole.AutomationJobs.Jobs.ExecuteRun.run(%Oban.Job{
        args: %{"automation_job_run_id" => id, "expected_slice_count" => slice},
        attempt: 1,
        max_attempts: 5
      })

  defp action_source(idempotent \\ true, max_slices \\ 1000),
    do: """
    export default {actions:{work:{idempotent:#{idempotent},concurrency:'serial_coalesce',
      concurrencyKey:ctx=>'key:'+ctx.job.id,maxSlices:#{max_slices},handler:async()=>({ok:true})}}}
    """

  defp bind(ctx, job),
    do:
      assert(
        {:ok, _} =
          Signals.put_event_binding(ctx.actor, %{
            config_ref: "applet://#{ctx.page.id}",
            automation_job_id: job.id
          })
      )

  defp emit(ctx, id),
    do: Signals.emit("applet://#{ctx.page.id}", %{id: id, type: "test.trigger", data: %{}})

  defp context(job, run),
    do: %{"job" => %{"id" => job.id}, "run" => %{"id" => run.id, "attemptId" => run.attempt_id}}
end
