defmodule Ankole.Repo.Migrations.RouteSourcesThroughBindings do
  use Ecto.Migration

  def up do
    insert_bindings(
      "SELECT tenant_id, id::text, agent_uid, automation_job_id FROM cron_schedules",
      fn
        [tenant, id, uid, job] ->
          binding(tenant, "schedule://#{id}", uid, "cron:#{id}", job, true)
      end
    )

    insert_bindings(
      """
      SELECT tenant_id, id::text, agent_uid, session_id, automation_job_id FROM scheduled_events
      WHERE kind='check_back_later' AND status='scheduled'
      """,
      fn [tenant, id, uid, session, job] ->
        binding(tenant, "scheduled-event://#{id}", uid, session, job, true)
      end
    )

    insert_bindings(
      """
      SELECT tenant_id, id::text, agent_uid, session_id, automation_job_id, status IN ('armed','active')
      FROM signal_webhook_endpoints WHERE event_format='raw'
      """,
      fn [tenant, id, uid, session, job, enabled] ->
        binding(tenant, "webhook-endpoint://#{id}", uid, session, job, enabled)
      end
    )

    execute("ALTER TABLE scheduled_events DROP CONSTRAINT scheduled_events_signal_id_fkey")
    flush()

    insert_bindings(
      """
      SELECT tenant_id,id::text,agent_uid,owner_session_id FROM automation_jobs WHERE executor_kind='agent_script'
      """,
      fn [tenant, id, uid, session] ->
        binding(tenant, "job://#{id}", uid, session, nil, true)
      end
    )

    # Cron history shares its rule's Binding. One-shot history needs a disabled
    # archival Binding because receipts retain that foreign key.
    rows("""
    SELECT s.tenant_id, s.id, s.agent_uid, s.session_id, s.automation_job_id,
      s.automation_job_run_id, s.signal_id, COALESCE(s.fired_at, s.updated_at) AT TIME ZONE 'UTC', b.id
    FROM scheduled_events s
    LEFT JOIN signal_bindings b ON b.tenant_id=s.tenant_id
      AND b.config_ref=CASE WHEN s.kind='cron_fire' AND s.cron_schedule_id IS NOT NULL
        THEN 'schedule://' || s.cron_schedule_id::text ELSE 'scheduled-event://' || s.id::text END
      AND b.name='source:' || b.config_ref
    WHERE s.automation_job_run_id IS NOT NULL OR s.signal_id IS NOT NULL
    """)
    |> Stream.chunk_every(1000)
    |> Enum.each(&migrate_history/1)

    execute("""
    WITH duplicates AS (SELECT id, row_number() OVER (PARTITION BY tenant_id,config_ref,agent_uid,target ORDER BY inserted_at,id) n
      FROM signal_bindings WHERE enabled AND adapter IN ('internal','cloudevents') AND agent_uid IS NOT NULL)
    UPDATE signal_bindings SET enabled=false FROM duplicates d WHERE d.id=signal_bindings.id AND d.n>1
    """)

    execute(
      "CREATE UNIQUE INDEX signal_bindings_event_target_unique ON signal_bindings(tenant_id,config_ref,agent_uid,target) WHERE enabled AND adapter IN ('internal','cloudevents') AND agent_uid IS NOT NULL"
    )

    execute("ALTER TABLE cron_schedules DROP COLUMN automation_job_id")

    execute(
      "ALTER TABLE scheduled_events DROP COLUMN automation_job_id, DROP COLUMN automation_job_run_id"
    )

    execute("ALTER TABLE signal_webhook_endpoints DROP COLUMN automation_job_id")
  end

  defp rows(sql) do
    repo()
    |> Ecto.Adapters.SQL.stream(sql, [], max_rows: 1000)
    |> Stream.flat_map(& &1.rows)
  end

  defp insert_bindings(sql, mapper) do
    rows(sql)
    |> Stream.map(mapper)
    |> Stream.chunk_every(1000)
    |> Enum.each(&insert_all("signal_bindings", &1))
  end

  defp insert_all(table, rows),
    do: Ankole.Repo.across_tenants(fn -> repo().insert_all(table, rows) end)

  defp binding(tenant, reference, uid, session, job, enabled) do
    now = DateTime.utc_now()

    %{
      id: uuid(),
      tenant_id: tenant,
      agent_uid: if(is_nil(job), do: uid),
      name: "source:#{reference}",
      routing_mode: if(job, do: "action", else: "ai_colleague"),
      adapter: "internal",
      config_ref: reference,
      target: if(job, do: %{}, else: %{"session_id" => session}),
      automation_job_id: job,
      enabled: enabled,
      inserted_at: now,
      updated_at: now
    }
  end

  defp migrate_history(rows) do
    {bindings, receipts, updates} =
      Enum.reduce(rows, {[], [], []}, fn row, {bindings, receipts, updates} ->
        [tenant, id, uid, session, job, run, signal, at, binding_id] = row

        archived =
          if is_nil(binding_id),
            do: binding(tenant, "scheduled-event://#{id}", uid, session, job, false)

        root = signal || uuid()

        receipt = %{
          tenant_id: tenant,
          binding_id: binding_id || archived.id,
          source: "ankole:schedule:#{id}",
          source_event_id: "migrated:#{id}",
          signal_id: Ecto.UUID.load!(root),
          automation_job_run_id: run,
          delivered_signal_id: if(signal, do: Ecto.UUID.load!(signal)),
          received_at: at
        }

        {if(archived, do: [archived | bindings], else: bindings), [receipt | receipts],
         [{tenant, id, root} | updates]}
      end)

    insert_all("signal_bindings", bindings)
    insert_all("signal_binding_receipts", receipts)

    repo().query!(
      """
      UPDATE scheduled_events s SET signal_id=u.signal_id
      FROM unnest($1::uuid[], $2::bigint[], $3::uuid[]) u(tenant_id,id,signal_id)
      WHERE s.tenant_id=u.tenant_id AND s.id=u.id
      """,
      [
        Enum.map(updates, &elem(&1, 0)),
        Enum.map(updates, &elem(&1, 1)),
        Enum.map(updates, &elem(&1, 2))
      ]
    )
  end

  defp uuid, do: Ecto.UUID.dump!(Ankole.Kernel.gen_uuid_v7())
  def down, do: raise("Signal routing history requires a forward migration")
end
