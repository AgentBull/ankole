defmodule Ankole.AutomationJobs.JobSourcesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2, publish_applet_fixture: 3]
  require Ash.Query
  alias Ankole.{AutomationJobs, Schedule, Signals}
  alias Ankole.AutomationJobs.JobSources
  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.Pod.Pages

  setup do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "applet"})
    ctx = %{actor: actor, page: page}

    publish_applet_fixture(ctx, """
    export default { actions: { work: { idempotent: true, concurrency: 'serial_fifo', handler: ctx => ctx.signal.data } } }
    """)

    {:ok, job} =
      AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "human"})

    Map.put(ctx, :job, job)
  end

  test "schedule edits require an existing ID, preserve omitted fields and record their creator",
       ctx do
    source = schedule(ctx)

    assert source.created_by["principal_uid"] ==
             to_string(Ankole.ActorRef.from_principal(ctx.actor.principal))

    assert {:ok, updated} = schedules(ctx, :put, %{id: source.id, payload: %{mode: "closing"}})
    assert updated.name == source.name
    assert updated.schedule == source.schedule
    assert updated.payload == %{"mode" => "closing"}

    assert {:error, :not_found} =
             schedules(ctx, :put, %{id: Ash.UUIDv7.generate(), name: "missing"})

    assert {:ok, [_]} = schedules(ctx, :list, %{})
  end

  test "a reauthorized source locks its Human before its owning Job", ctx do
    source = schedule(ctx)
    assert {:ok, _} = schedules(ctx, :pause, %{id: source.id})
    human = human_fixture().principal

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Ash.update(
                 source,
                 :reauthorize,
                 Ankole.Principals.WorkAccess.from_sender(human.uid)
               )
             end)

    assert {:ok, %{status: :active}} = schedules(ctx, :resume, %{id: source.id})

    assert {:ok, %{status: :scheduled}} =
             schedules(ctx, :run, %{id: source.id, idempotency_key: "reauthorized-source"})
  end

  test "a terminal webhook keeps its history and rejects further edits", ctx do
    {:ok, %{webhook_endpoint: endpoint, token: token}} =
      webhooks(ctx, :create, %{
        label: "receipt",
        mode: "one_shot",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert {:ok, %{status: :accepted}} = Signals.Webhooks.receive(token, [], "receipt")

    for operation <- [:pause, :resume, :update] do
      assert {:error, :webhook_terminal} =
               webhooks(ctx, operation, %{id: endpoint.id, label: "changed"})
    end

    assert %{status: :fired, label: "receipt"} = Signals.Webhooks.get_endpoint(endpoint.id)
    assert {:ok, %{status: :fired}} = webhooks(ctx, :delete, %{id: endpoint.id})
  end

  test "deleting an absent Job reports not found", ctx do
    assert {:error, :not_found} =
             AutomationJobs.delete_applet_job(ctx.actor, ctx.page.id, 9_223_372_036_854_775_000)
  end

  test "Page viewers can inspect subscriptions without acquiring edit permission", ctx do
    other = actor_fixture(human_fixture().principal.uid)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
        grants: [%{principal_uid: other.principal.uid, role: "view"}]
      })

    reference = "applet://#{ctx.page.id}"
    assert {:ok, []} = Signals.list_event_bindings(other, reference)

    assert {:error, :forbidden} =
             Signals.put_event_binding(other, %{
               config_ref: reference,
               automation_job_id: ctx.job.id
             })
  end

  test "Job cron delivers business input and slot times without creating a Session Signal", ctx do
    schedule = schedule(ctx)
    assert schedule.agent_uid == nil
    assert schedule.owner_session_id == nil
    assert schedule.delivery == nil
    assert {:ok, result} = Schedule.fire_cron(schedule.id, now: schedule.next_fire_at)
    assert result.signals == []
    assert result.automation_job_run.event["data"]["mode"] == "intraday"

    assert result.automation_job_run.event["data"]["cron_fire_slot_at"] ==
             DateTime.to_iso8601(schedule.next_fire_at)

    assert result.automation_job_run.event["data"]["fired_at"] ==
             DateTime.to_iso8601(schedule.next_fire_at)

    assert Ankole.Ash.count!(Signals.Signal) == 0
    assert [%{automation_job_run_id: run_id}] = result.deliveries
    assert run_id == result.automation_job_run.id

    assert :ok =
             ExecuteRun.run(%Oban.Job{
               args: %{"automation_job_run_id" => run_id},
               attempt: 1,
               max_attempts: 5
             })

    assert %{status: :succeeded, result: %{"mode" => "intraday"}} =
             AutomationJobs.get_run_record(run_id)
  end

  test "Job schedules pause, resume, and deduplicate manual runs", ctx do
    schedule = schedule(ctx)
    assert {:ok, %{status: :paused}} = schedules(ctx, :pause, %{id: schedule.id})
    assert {:ok, %{status: :active}} = schedules(ctx, :resume, %{id: schedule.id})
    attrs = %{id: schedule.id, idempotency_key: "manual-one"}
    assert {:ok, %{status: :scheduled, scheduled_event: first}} = schedules(ctx, :run, attrs)

    assert {:ok, %{status: :already_scheduled, scheduled_event: second}} =
             schedules(ctx, :run, attrs)

    assert first.id == second.id
    assert first.session_id == nil
    assert {:ok, %{events: [_], deliveries: []}} = schedules(ctx, :runs, %{id: schedule.id})
  end

  test "a removed schedule name can be reused while its old history stays readable", ctx do
    previous = schedule(ctx)
    assert {:ok, %{status: :deleted}} = schedules(ctx, :delete, %{id: previous.id})
    current = schedule(ctx)
    refute current.id == previous.id
    assert {:ok, [%{id: id}]} = schedules(ctx, :list, %{})
    assert id == current.id
    assert {:ok, %{events: [], deliveries: []}} = schedules(ctx, :runs, %{id: previous.id})
  end

  test "paused one-shot webhook does not consume its capability and resumes without an Agent",
       ctx do
    assert {:ok, %{webhook_endpoint: endpoint, token: token}} =
             webhooks(ctx, :create, %{
               label: "receipt",
               mode: "one_shot",
               expires_at: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert endpoint.owner_job_id == ctx.job.id
    assert {:ok, %{status: :paused}} = webhooks(ctx, :pause, %{id: endpoint.id})

    assert {:ok, %{status: :ignored, webhook_endpoint: %{status: :paused}}} =
             Signals.Webhooks.receive(token, [], "hello")

    assert {:ok, %{status: :armed}} = webhooks(ctx, :resume, %{id: endpoint.id})

    assert {:ok,
            %{
              status: :accepted,
              signals: [],
              automation_job_run: run,
              webhook_endpoint: %{status: :fired}
            }} = Signals.Webhooks.receive(token, [], "hello")

    assert run.event["data"]["body"] == "hello"
    assert {:ok, [%{deliveries: [%{automation_job_run_id: id}]}]} = webhooks(ctx, :list, %{})
    assert id == run.id
  end

  test "trashed Page skips slots and webhook deliveries, then resumes when restored", ctx do
    schedule = schedule(ctx)

    {:ok, %{webhook_endpoint: endpoint, token: token}} =
      webhooks(ctx, :create, %{
        label: "receipt",
        mode: "one_shot",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert {:ok, _} = Pages.delete(ctx.actor, ctx.page.id)

    assert {:ok, %{status: :cancelled}} =
             Schedule.fire_cron(schedule.id, now: schedule.next_fire_at)

    assert {:ok, %{status: :ignored, webhook_endpoint: %{status: :armed}}} =
             Signals.Webhooks.receive(token, [], "ignored")

    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 0
    assert {:ok, _} = Pages.restore(ctx.actor, ctx.page.id)
    assert {:ok, %{status: :accepted}} = Signals.Webhooks.receive(token, [], "restored")
    assert Signals.Webhooks.get_endpoint(endpoint.id).status == :fired
    {:ok, current} = Schedule.get_cron_schedule(schedule.id)
    assert current.status == :active
    assert DateTime.after?(current.next_fire_at, schedule.next_fire_at)
  end

  test "deleting Job removes its sources, receipts and runs", ctx do
    schedule = schedule(ctx)

    {:ok, %{webhook_endpoint: endpoint}} =
      webhooks(ctx, :create, %{
        label: "receipt",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    {:ok, _} = Schedule.fire_cron(schedule.id, now: schedule.next_fire_at)
    assert {:ok, _} = AutomationJobs.delete_applet_job(ctx.actor, ctx.page.id, ctx.job.id)
    assert {:ok, nil} = AutomationJobs.get_automation_job(ctx.job.id)
    assert Signals.Webhooks.get_endpoint(endpoint.id) == nil
    assert Ankole.Schedule.Store.get_cron_schedule(schedule.id) == nil
    assert Ankole.Ash.count!(Signals.BindingReceipt) == 0
    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 0
  end

  test "another member cannot manage a personal Job's sources", ctx do
    other = actor_fixture(human_fixture().principal.uid)
    assert {:error, :forbidden} = JobSources.schedules(other, ctx.page.id, ctx.job.id, :list)
  end

  test "editing recurrence preserves its Action default while another Job receives fanout", ctx do
    source = schedule(ctx)

    {:ok, second} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "human"
      })

    assert {:ok, _} =
             Signals.put_event_binding(ctx.actor, %{
               config_ref: "schedule://#{source.id}",
               automation_job_id: second.id
             })

    assert {:ok, updated} =
             schedules(ctx, :put, %{id: source.id, name: source.name, payload: %{mode: "closing"}})

    assert Signals.source_automation_job_id(updated) == ctx.job.id
    assert {:ok, result} = Schedule.fire_cron(source.id, now: source.next_fire_at)
    assert result.signals == []
    assert length(result.deliveries) == 2
    runs = Enum.map(result.deliveries, &AutomationJobs.get_run_record(&1.automation_job_run_id))
    assert Enum.sort(Enum.map(runs, & &1.automation_job_id)) == Enum.sort([ctx.job.id, second.id])
    assert Enum.all?(runs, &(&1.event["data"]["mode"] == "closing"))

    default =
      Signals.Binding
      |> Ash.Query.filter(
        config_ref == ^"schedule://#{source.id}" and name == ^"source:schedule://#{source.id}"
      )
      |> Ankole.Ash.read_one!()

    assert {:error, :source_binding_managed_by_owner} =
             Signals.put_event_binding(ctx.actor, %{
               id: default.id,
               config_ref: default.config_ref,
               automation_job_id: second.id
             })
  end

  test "a delayed scheduler consumes one due slot and advances past the outage", ctx do
    source = schedule(ctx)
    late = DateTime.add(source.next_fire_at, 1800)
    assert {:ok, %{deliveries: [_]}} = Schedule.fire_cron(source.id, now: late)
    assert {:ok, current} = Schedule.get_cron_schedule(source.id)
    assert DateTime.after?(current.next_fire_at, late)
    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 1
    assert {:ok, %{status: :noop}} = Schedule.fire_cron(source.id, now: late)
  end

  test "personal revocation stops owned schedules and endpoints", ctx do
    source = schedule(ctx)

    {:ok, %{webhook_endpoint: endpoint, token: token}} =
      webhooks(ctx, :create, %{
        label: "receipt",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert {:ok, disabled} =
             Ankole.Principals.HumanAccess.disable(
               ctx.actor.principal.uid,
               "Offboarding",
               nil,
               "sources-test"
             )

    assert {:ok, _} =
             Ankole.Principals.WorkCleanup.cleanup(
               ctx.actor.principal.uid,
               disabled.access_version
             )

    assert {:ok, %{status: :cancelled}} = AutomationJobs.get_automation_job(ctx.job.id)
    assert {:ok, %{status: :paused}} = Schedule.get_cron_schedule(source.id)
    assert Signals.Webhooks.get_endpoint(endpoint.id).status == :paused
    assert {:error, :human_access_revoked} = Signals.Webhooks.receive(token, [], "stopped")
    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 0

    assert {:ok, _} =
             Ankole.Principals.HumanAccess.restore(
               ctx.actor.principal.uid,
               nil,
               "Returned member",
               "sources-restored"
             )

    restored = %{ctx | actor: actor_fixture(ctx.actor.principal.uid)}
    assert {:ok, [%{status: :paused}]} = schedules(restored, :list, %{})
    assert {:ok, %{events: [], deliveries: []}} = schedules(restored, :runs, %{id: source.id})
    assert {:ok, [%{endpoint: %{status: :paused}}]} = webhooks(restored, :list, %{})
    assert {:error, :human_access_revoked} = schedules(restored, :resume, %{id: source.id})
    assert {:error, :human_access_revoked} = webhooks(restored, :resume, %{id: endpoint.id})
  end

  test "serial coalescing keeps each receipt linked to the surviving Run", ctx do
    publish_applet_fixture(
      ctx,
      """
      export default { actions: { work: { idempotent: true, concurrency: 'serial_coalesce', handler: ctx => ctx.signal.data } } }
      """,
      1
    )

    {:ok, %{token: token}} =
      webhooks(ctx, :create, %{
        label: "stream",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert {:ok, %{automation_job_run: first}} = Signals.Webhooks.receive(token, [], "one")
    assert {:ok, %{automation_job_run: second}} = Signals.Webhooks.receive(token, [], "two")
    assert first.id == second.id
    assert {:ok, [%{deliveries: deliveries}]} = webhooks(ctx, :list, %{})
    assert length(deliveries) == 2
    assert Enum.all?(deliveries, &(&1.automation_job_run_id == first.id))
    assert Enum.count(deliveries, & &1.coalesced) == 1
  end

  test "source history reads Run statuses in one batch", ctx do
    {:ok, %{token: token}} =
      webhooks(ctx, :create, %{
        label: "history",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    for body <- ["one", "two", "three"] do
      assert {:ok, %{status: :accepted}} = Signals.Webhooks.receive(token, [], body)
    end

    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and metadata.query =~ ~s(FROM "automation_job_runs"),
            do: send(owner, {:history_run_query, handler})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, [%{deliveries: deliveries}]} = webhooks(ctx, :list, %{})
    assert length(deliveries) == 3
    assert Enum.all?(deliveries, &(&1.run_status == :queued))
    assert_receive {:history_run_query, ^handler}
    refute_received {:history_run_query, ^handler}
  end

  test "webhook history keeps each source's newest 100 across consumers with four queries", ctx do
    {:ok, second_job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "human"
      })

    endpoints =
      for label <- ["first history", "second history"] do
        {:ok, %{webhook_endpoint: endpoint, token: token}} =
          webhooks(ctx, :create, %{
            label: label,
            expires_at: DateTime.add(DateTime.utc_now(), 3600)
          })

        {:ok, _} =
          Signals.put_event_binding(ctx.actor, %{
            config_ref: "webhook-endpoint://#{endpoint.id}",
            automation_job_id: second_job.id
          })

        assert {:ok, %{deliveries: [_, _]}} = Signals.Webhooks.receive(token, [], "latest")
        endpoint
      end

    old = DateTime.add(DateTime.utc_now(:microsecond), -3600)

    for {endpoint, source_index} <- Enum.with_index(endpoints) do
      reference = "webhook-endpoint://#{endpoint.id}"
      bindings = Signals.list_bindings!(query: [filter: [config_ref: reference]])
      assert length(bindings) == 2

      templates =
        for binding <- bindings do
          Repo.get_by!(Signals.BindingReceipt, binding_id: binding.id)
        end

      # Retained historical receipts share the real consumers and Run references above.
      # Each binding exceeds 100, and the two sources' timestamps interleave.
      rows =
        for index <- 1..220 do
          template = Enum.at(templates, rem(index, 2))

          %{
            tenant_id: Repo.tenant_id!(),
            binding_id: template.binding_id,
            source: template.source,
            source_event_id: "history-#{endpoint.id}-#{index}",
            signal_id: "history-#{endpoint.id}-#{index}",
            automation_job_run_id: template.automation_job_run_id,
            received_at: DateTime.add(old, index * 2 + source_index, :microsecond)
          }
        end

      Repo.insert_all(Signals.BindingReceipt, rows)
    end

    {:ok, %{webhook_endpoint: empty}} =
      webhooks(ctx, :create, %{
        label: "no deliveries",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    handler = {__MODULE__, make_ref()}
    owner = self()

    tables =
      ~w(signal_webhook_endpoints signal_bindings signal_binding_receipts automation_job_runs)

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, "SELECT") and
               Enum.any?(tables, &String.contains?(metadata.query, ~s("#{&1}"))),
             do: send(owner, {handler, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, result} = webhooks(ctx, :list, %{})

    for endpoint <- endpoints do
      %{deliveries: deliveries} = Enum.find(result, &(&1.endpoint.id == endpoint.id))
      assert length(deliveries) == 100
      assert Enum.all?(deliveries, &(&1.run_status == :queued))
      assert Enum.count(deliveries, & &1.coalesced) == 98

      assert Enum.map(Enum.drop(deliveries, 2), & &1.source_event_id) ==
               Enum.map(220..123//-1, &"history-#{endpoint.id}-#{&1}")
    end

    assert %{deliveries: []} = Enum.find(result, &(&1.endpoint.id == empty.id))
    for _ <- 1..4, do: assert_received({^handler, _query})
    refute_received {^handler, _extra_query}
  end

  test "coalescing distinguishes the same event ID delivered by different sources", ctx do
    [first, second] = coalescing_sources(ctx)

    event = %{
      "specversion" => "1.0",
      "id" => "record-42",
      "source" => "https://provider.example/events",
      "type" => "record.updated",
      "data" => %{"version" => 1}
    }

    assert {:ok, %{automation_job_run: initial}} =
             Signals.Webhooks.receive_cloudevent(first.token, event)

    assert {:ok, %{automation_job_run: surviving}} =
             Signals.Webhooks.receive_cloudevent(
               second.token,
               put_in(event, ["data", "version"], 2)
             )

    assert initial.id == surviving.id
    assert surviving.event["source"] == "ankole:webhook:#{second.webhook_endpoint.id}"
    assert surviving.event["data"]["version"] == 2
    assert {:ok, history} = webhooks(ctx, :list, %{})
    by_id = Map.new(history, &{&1.endpoint.id, &1.deliveries})
    assert [%{coalesced: true, automation_job_run_id: id}] = by_id[first.webhook_endpoint.id]
    assert id == surviving.id
    assert [%{coalesced: false, automation_job_run_id: ^id}] = by_id[second.webhook_endpoint.id]
  end

  test "bounded CloudEvents pairs preserve source-scoped deduplication and receipt identity",
       ctx do
    sources = coalescing_sources(ctx)
    identities = for source <- 0..1, id <- 0..1, do: {source, id}
    pairs = for first <- identities, second <- identities, do: [first, second]

    for {identities, case_id} <- Enum.with_index(pairs) do
      accepted = Enum.uniq(identities)
      expected_identity = List.last(accepted)
      expected_value = if length(accepted) == 1, do: 0, else: 1

      runs =
        for {{source_index, event_id}, value} <- Enum.with_index(identities) do
          source = Enum.at(sources, source_index)

          event = %{
            "specversion" => "1.0",
            "id" => "case-#{case_id}-#{event_id}",
            "source" => "https://provider.example/events",
            "type" => "record.updated",
            "data" => %{"value" => value}
          }

          assert {:ok, %{automation_job_run: run}} =
                   Signals.Webhooks.receive_cloudevent(source.token, event)

          run
        end

      assert Enum.uniq_by(runs, & &1.id) |> length() == 1
      assert List.last(runs).event["data"]["value"] == expected_value
      assert {:ok, history} = webhooks(ctx, :list, %{})

      receipts =
        for {source, source_index} <- Enum.with_index(sources),
            entry <- history,
            entry.endpoint.id == source.webhook_endpoint.id,
            receipt <- entry.deliveries,
            String.starts_with?(receipt.source_event_id, "case-#{case_id}-") do
          id =
            String.to_integer(
              String.replace_prefix(receipt.source_event_id, "case-#{case_id}-", "")
            )

          {{source_index, id}, receipt.coalesced}
        end

      assert Map.new(receipts) == Map.new(accepted, &{&1, &1 != expected_identity})
    end
  end

  test "an independent source records a trashed consumer's failed Run and delivers after restore",
       ctx do
    {:ok, other_page} = Pages.create(ctx.actor, %{type: "applet"})
    other = %{actor: ctx.actor, page: other_page}

    publish_applet_fixture(
      other,
      "export default {actions:{work:{handler:ctx=>ctx.signal.data}}}"
    )

    {:ok, other_job} =
      AutomationJobs.create_applet_job(ctx.actor, other_page.id, "work", %{
        authorization_kind: "service"
      })

    {:ok, %{webhook_endpoint: endpoint, token: token}} =
      webhooks(ctx, :create, %{
        label: "shared source",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert {:ok, _} =
             Signals.put_event_binding(ctx.actor, %{
               config_ref: "webhook-endpoint://#{endpoint.id}",
               automation_job_id: other_job.id
             })

    assert {:ok, _} = Pages.delete(ctx.actor, other_page.id)
    assert {:ok, %{deliveries: deliveries}} = Signals.Webhooks.receive(token, [], "while trashed")
    assert length(deliveries) == 2
    runs = Enum.map(deliveries, &AutomationJobs.get_run_record(&1.automation_job_run_id))
    unavailable = Enum.find(runs, &(&1.automation_job_id == other_job.id))
    assert Enum.any?(runs, &(&1.automation_job_id == ctx.job.id and &1.status == :queued))

    assert :ok =
             ExecuteRun.run(%Oban.Job{
               args: %{"automation_job_run_id" => unavailable.id},
               attempt: 1,
               max_attempts: 5
             })

    assert %{status: :failed, error: "page_trashed"} =
             AutomationJobs.get_run_record(unavailable.id)

    assert Signals.Webhooks.get_endpoint(endpoint.id).status == :active
    assert {:ok, _} = Pages.restore(ctx.actor, other_page.id)
    assert {:ok, %{deliveries: deliveries}} = Signals.Webhooks.receive(token, [], "after restore")
    assert length(deliveries) == 2

    restored =
      deliveries
      |> Enum.map(&AutomationJobs.get_run_record(&1.automation_job_run_id))
      |> Enum.find(&(&1.automation_job_id == other_job.id))

    assert :ok =
             ExecuteRun.run(%Oban.Job{
               args: %{"automation_job_run_id" => restored.id},
               attempt: 1,
               max_attempts: 5
             })

    assert %{status: :succeeded} = AutomationJobs.get_run_record(restored.id)
  end

  test "one disabled membership cycle revokes old work while restoration permits fresh personal Jobs",
       ctx do
    uid = ctx.actor.principal.uid
    captured = ctx.job.human_access_version
    source = schedule(ctx)

    assert {:ok, suspended} =
             Ankole.Principals.HumanAccess.disable(
               uid,
               "Temporary suspension",
               nil,
               "cycle-suspend",
               :suspended
             )

    assert suspended.access_version == captured + 1

    assert {:ok, departed} =
             Ankole.Principals.HumanAccess.disable(
               uid,
               "Departure",
               nil,
               "cycle-offboard",
               :offboarded
             )

    assert departed.access_version == suspended.access_version

    assert {:ok, restored} =
             Ankole.Principals.HumanAccess.restore(uid, nil, "Returned", "cycle-restore")

    assert restored.access_version == suspended.access_version
    actor = actor_fixture(uid)

    assert {:error, :human_access_revoked} =
             JobSources.schedules(actor, ctx.page.id, ctx.job.id, :run, %{id: source.id})

    assert {:ok, fresh} =
             AutomationJobs.create_applet_job(actor, ctx.page.id, "work", %{
               authorization_kind: "human"
             })

    assert fresh.human_access_version == restored.access_version

    assert {:ok, _} =
             JobSources.webhooks(actor, ctx.page.id, fresh.id, :create, %{
               label: "fresh authorization",
               expires_at: DateTime.add(DateTime.utc_now(), 3600)
             })
  end

  test "Humans and their personal assistants share the personal and team source permission matrix",
       ctx do
    member = human_fixture().principal
    actor = actor_fixture(member.uid)

    %{principal: assistant} =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: member.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: member.uid, role: "edit"}]
      })

    {:ok, personal} =
      AutomationJobs.create_applet_job(actor, ctx.page.id, "work", %{authorization_kind: "human"})

    {:ok, team} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "work", %{
        authorization_kind: "service"
      })

    for role <- ["view", "contribute", "edit"] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, ctx.page.id, %{
          grants: [%{principal_uid: member.uid, role: role}]
        })

      for principal <- [member, assistant], job <- [personal, team] do
        actor = actor_fixture(principal.uid)
        assert {:ok, _} = JobSources.schedules(actor, ctx.page.id, job.id, :list)
        assert {:ok, _} = JobSources.webhooks(actor, ctx.page.id, job.id, :list)
        assert {:error, :forbidden} = JobSources.schedules(actor, ctx.page.id, ctx.job.id, :list)

        result =
          JobSources.webhooks(actor, ctx.page.id, job.id, :create, %{
            label: "#{role}:#{principal.uid}:#{job.id}",
            expires_at: DateTime.add(DateTime.utc_now(), 3600)
          })

        if role == "edit" or (role == "contribute" and job.id == personal.id) do
          assert {:ok, %{webhook_endpoint: endpoint}} = result
          assert endpoint.authorization_kind == job.authorization_kind
          assert endpoint.human_uid == job.human_uid
          assert endpoint.human_access_version == job.human_access_version
        else
          assert {:error, :forbidden} = result
        end
      end
    end
  end

  test "an ancestor's trash cycle preserves a cron occurrence and a one-shot callback", ctx do
    {:ok, folder} = Pages.create(ctx.actor, %{title: "Automation folder"})
    assert {:ok, _} = Pages.move(ctx.actor, ctx.page.id, %{parent_id: folder.id})

    {:ok, source} =
      schedules(ctx, :put, %{
        name: "one occurrence",
        schedule: %{
          kind: "every",
          every_ms: 60_000,
          anchor_at: DateTime.to_iso8601(DateTime.utc_now()),
          occurrences: %{count: 1}
        },
        timezone: "Etc/UTC",
        payload: %{value: "after restoration"}
      })

    {:ok, %{webhook_endpoint: endpoint, token: token}} =
      webhooks(ctx, :create, %{
        label: "one callback",
        mode: "one_shot",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    assert {:ok, _} = Pages.delete(ctx.actor, folder.id)
    assert {:ok, %{deleted_at: nil}} = Pages.fetch(ctx.page.id)

    for _ <- 1..3 do
      {:ok, current} = Schedule.get_cron_schedule(source.id)
      assert current.status == :active

      assert {:ok, %{status: :cancelled}} =
               Schedule.fire_cron(source.id, now: current.next_fire_at)

      assert {:ok, %{status: :ignored}} =
               Signals.Webhooks.receive(token, [], "while ancestor trashed")
    end

    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 0
    assert Signals.Webhooks.get_endpoint(endpoint.id).status == :armed
    assert {:ok, _} = Pages.restore(ctx.actor, folder.id)
    {:ok, current} = Schedule.get_cron_schedule(source.id)
    assert {:ok, %{status: :fired}} = Schedule.fire_cron(source.id, now: current.next_fire_at)
    assert {:ok, %{status: :completed}} = Schedule.get_cron_schedule(source.id)
    assert {:ok, %{status: :accepted}} = Signals.Webhooks.receive(token, [], "restored")
    assert {:ok, %{status: :ignored}} = Signals.Webhooks.receive(token, [], "duplicate callback")
    assert Ankole.Ash.count!(AutomationJobs.Schemas.Run) == 2
    assert Ankole.Ash.count!(Signals.Signal) == 0
  end

  defp coalescing_sources(ctx) do
    publish_applet_fixture(
      ctx,
      """
      export default { actions: { work: { idempotent: true, concurrency: 'serial_coalesce', handler: ctx => ctx.signal.data } } }
      """,
      1
    )

    for label <- ["first source", "second source"] do
      assert {:ok, endpoint} =
               webhooks(ctx, :create, %{
                 label: label,
                 event_format: "cloudevents",
                 expires_at: DateTime.add(DateTime.utc_now(), 3600)
               })

      endpoint
    end
  end

  defp schedule(ctx) do
    {:ok, schedule} =
      schedules(ctx, :put, %{
        name: "intraday",
        schedule: %{kind: "cron", expression: "*/10 9-11,13-15 * * 1-5"},
        timezone: "Asia/Shanghai",
        payload: %{mode: "intraday"}
      })

    schedule
  end

  defp schedules(ctx, operation, attrs),
    do: JobSources.schedules(ctx.actor, ctx.page.id, ctx.job.id, operation, attrs)

  defp webhooks(ctx, operation, attrs),
    do: JobSources.webhooks(ctx.actor, ctx.page.id, ctx.job.id, operation, attrs)
end
