# Run with MIX_ENV=test MIX_TEST_PARTITION=<fresh-name> mix run --no-start in a disposable database.
import ExUnit.Assertions
alias Ankole.Repo
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:tzdata)
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, :verified, _} =
  Ecto.Migrator.with_repo(Repo, fn repo ->
    Ecto.Migrator.run(repo, Ankole.Migrations.paths(), :up, to: 20_261_103_005_899, log: false)
    [[tenant]] = repo.query!("SELECT id::text FROM tenants ORDER BY id LIMIT 1").rows
    uuid = fn -> Ankole.Kernel.gen_uuid_v7() end
    page = uuid.()
    signal = uuid.()
    cron = uuid.()
    webhook = uuid.()
    conversation = uuid.()

    repo.query!(
      """
      INSERT INTO principals(tenant_id,uid,type,status,membership,display_name,inserted_at,updated_at)
      VALUES($1::text::uuid,'migration-owner','human','active','member','Owner',now(),now()),
        ($1::text::uuid,'migration-agent','agent','active',NULL,'Agent',now(),now())
      """,
      [tenant]
    )

    repo.query!(
      """
      INSERT INTO agents(tenant_id,uid,type,role,owner_principal_uid,inserted_at,updated_at)
      VALUES($1::text::uuid,'migration-agent','ai_colleague','Migration','migration-owner',now(),now())
      """,
      [tenant]
    )

    repo.query!(
      """
      INSERT INTO conversations(tenant_id,id,kind,title,created_by,room_mode,native_access_scope,last_activity_at,inserted_at,updated_at)
      VALUES($1::text::uuid,$2::text::uuid,'native','Historical schedule destination','migration-owner','dm','participants',now(),now(),now())
      """,
      [tenant, conversation]
    )

    repo.query!(
      """
      INSERT INTO conversation_participants(tenant_id,conversation_id,principal_uid,role,may_intervene)
      VALUES($1::text::uuid,$2::text::uuid,'migration-owner','owner',false),
        ($1::text::uuid,$2::text::uuid,'migration-agent','agent',true)
      """,
      [tenant, conversation]
    )

    repo.query!(
      """
      INSERT INTO drive_nodes(tenant_id,id,parent_id,name,kind,acl_anchor_id,parent_anchor_id,created_by)
      SELECT tenant_id,$2::text::uuid,id,'Historical Applet','applet',acl_anchor_id,NULL,
        'ankole:'||$1||':principal/migration-owner' FROM drive_nodes
      WHERE tenant_id=$1::text::uuid AND parent_id IS NULL AND private_owner_uid IS NULL AND conversation_id IS NULL
      """,
      [tenant, page]
    )

    repo.query!(
      """
      INSERT INTO automation_jobs(tenant_id,id,agent_uid,owner_session_id,drive_prefix,label,authorization_kind,inserted_at,updated_at)
      VALUES($1::text::uuid,9000,'migration-agent','migration','automation/migration','Historical Job','service',now(),now())
      """,
      [tenant]
    )

    repo.query!(
      """
      INSERT INTO automation_job_runs(tenant_id,id,automation_job_id,event,status,finished_at,inserted_at,updated_at)
      VALUES($1::text::uuid,9001,9000,'{}','succeeded',now()-interval '30 days',now()-interval '30 days',now()-interval '30 days')
      """,
      [tenant]
    )

    repo.query!(
      """
      INSERT INTO signals(tenant_id,id,agent_uid,source,session_id,source_event_id,type,available_at,queue_sequence,data,authorization_kind,occurred_at,inserted_at,updated_at)
      VALUES($1::text::uuid,$2::text::uuid,'migration-agent','schedule','migration','old-agent-fire','schedule.fired',now(),1,'{}','service',now(),now(),now())
      """,
      [tenant, signal]
    )

    repo.query!(
      """
      INSERT INTO cron_schedules(tenant_id,id,status,agent_uid,owner_session_id,name,schedule,timezone,payload,delivery,next_fire_at,idempotency_key,automation_job_id,authorization_kind,inserted_at,updated_at)
      VALUES($1::text::uuid,$2::text::uuid,'active','migration-agent','migration','Historical cron','{"kind":"cron","expression":"0 * * * *","timezone":"UTC"}','UTC','{}',
        jsonb_build_object('targets',jsonb_build_array(jsonb_build_object('conversation_id',$3::text))),now(),'cron',9000,'service',now(),now())
      """,
      [tenant, cron, conversation]
    )

    for {id, status, job, run, delivered} <- [
          {9002, "scheduled", 9000, nil, nil},
          {9003, "fired", 9000, 9001, nil},
          {9004, "fired", nil, nil, signal}
        ] do
      repo.query!(
        """
        INSERT INTO scheduled_events(tenant_id,id,kind,status,agent_uid,session_id,due_at,timezone,requested_at,idempotency_key,automation_job_id,automation_job_run_id,signal_id,authorization_kind,fired_at,inserted_at,updated_at)
        VALUES($1::text::uuid,$2,'check_back_later',$3,'migration-agent','migration',now(),'UTC',now(),($2::bigint)::text,$4,$5,$6::text::uuid,'service',CASE WHEN $3='fired' THEN now()-interval '30 days' END,now()-interval '30 days',now()-interval '30 days')
        """,
        [tenant, id, status, job, run, delivered]
      )
    end

    repo.query!(
      """
      INSERT INTO signal_webhook_endpoints(tenant_id,id,token_digest,agent_uid,session_id,label,mode,status,expires_at,automation_job_id,inserted_at,updated_at)
      VALUES($1::text::uuid,$2::text::uuid,$3,'migration-agent','migration','Historical webhook','standing','active',now()+interval '30 days',9000,now(),now())
      """,
      [tenant, webhook, String.duplicate("a", 43)]
    )

    repo.query!(
      """
      INSERT INTO automation_job_runs(tenant_id,id,automation_job_id,event,status,finished_at,inserted_at,updated_at)
      SELECT $1::text::uuid,n,9000,'{}','succeeded',now()-interval '30 days',now()-interval '30 days',now()-interval '30 days'
      FROM generate_series(10000,11000) n
      """,
      [tenant]
    )

    repo.query!(
      """
      INSERT INTO scheduled_events(tenant_id,id,kind,status,agent_uid,session_id,due_at,timezone,requested_at,
        idempotency_key,automation_job_id,automation_job_run_id,authorization_kind,fired_at,inserted_at,updated_at,
        cron_schedule_id,cron_fire_slot_at)
      SELECT $1::text::uuid,n,'cron_fire','fired','migration-agent','cron:'||$2,now(),'UTC',now(),
        n::text,9000,n,'service',now()-interval '30 days',now()-interval '30 days',now()-interval '30 days',
        $2::text::uuid, now()-interval '30 days'+n*interval '1 hour'
      FROM generate_series(10000,11000) n
      """,
      [tenant, cron]
    )

    # Verify the historical routing conversion before the later migration
    # deliberately removes the retired Agent-script executor and its deliveries.
    Ecto.Migrator.run(repo, Ankole.Migrations.paths(), :up, to: 20_261_104_120_000, log: false)

    assert [["migration-owner"]] ==
             repo.query!(
               "SELECT owner_uid FROM pages WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
               [tenant, page]
             ).rows

    for reference <- [
          "schedule://#{cron}",
          "scheduled-event://9002",
          "webhook-endpoint://#{webhook}"
        ] do
      assert [["action", 9000]] ==
               repo.query!(
                 "SELECT routing_mode,automation_job_id FROM signal_bindings WHERE tenant_id=$1::text::uuid AND config_ref=$2",
                 [tenant, reference]
               ).rows
    end

    assert [[0]] ==
             repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_name IN ('cron_schedules','scheduled_events','signal_webhook_endpoints') AND column_name IN ('automation_job_id','automation_job_run_id')"
             ).rows

    assert [["ai_colleague", "migration-agent"]] ==
             repo.query!(
               "SELECT routing_mode,agent_uid FROM signal_bindings WHERE tenant_id=$1::text::uuid AND config_ref='job://9000'",
               [tenant]
             ).rows

    assert [[1003, 1002, 1]] ==
             repo.query!(
               "SELECT count(*),count(automation_job_run_id),count(delivered_signal_id) FROM signal_binding_receipts WHERE tenant_id=$1::text::uuid",
               [tenant]
             ).rows

    assert [[1001, 1]] ==
             repo.query!(
               """
               SELECT count(*),count(DISTINCT r.binding_id) FROM signal_binding_receipts r
               JOIN signal_bindings b ON b.tenant_id=r.tenant_id AND b.id=r.binding_id
               WHERE r.tenant_id=$1::text::uuid AND b.config_ref='schedule://' || $2
               """,
               [tenant, cron]
             ).rows

    assert [[0]] ==
             repo.query!(
               """
               SELECT count(*) FROM signal_bindings WHERE tenant_id=$1::text::uuid
               AND config_ref LIKE 'scheduled-event://1%'
               """,
               [tenant]
             ).rows

    assert [[false], [false]] ==
             repo.query!(
               """
               SELECT enabled FROM signal_bindings WHERE tenant_id=$1::text::uuid
               AND config_ref IN ('scheduled-event://9003','scheduled-event://9004')
               """,
               [tenant]
             ).rows

    assert [[signal]] ==
             repo.query!(
               "SELECT signal_id::text FROM scheduled_events WHERE tenant_id=$1::text::uuid AND id=9004",
               [tenant]
             ).rows

    Repo.with_tenant(tenant, fn ->
      for {id, run, delivered} <- [{9003, 9001, nil}, {9004, nil, signal}] do
        {:ok, event} = Ankole.Schedule.get_checkback(id)
        projection = Ankole.Schedule.Projections.event_model_projection(event)
        assert projection["automation_job_run_id"] == run

        assert [%{automation_job_run_id: ^run, delivered_signal_id: ^delivered}] =
                 projection["deliveries"]
      end

      # Retention must preserve history even when its original receipt is older than seven days.
      assert :ok = Ankole.Signals.Dispatch.expire_receipts(DateTime.utc_now())
      assert length(Ankole.Signals.delivery_receipts(signal)) == 1
    end)

    retained_binding = uuid.()

    repo.query!(
      """
      INSERT INTO automation_jobs(tenant_id,id,executor_kind,page_id,action_key,label,
        authorization_kind,wake_on_failure,inserted_at,updated_at)
      VALUES($1::text::uuid,9100,'applet_function',$2::text::uuid,'retained',
        'Retained Applet Job','service',false,now(),now())
      """,
      [tenant, page]
    )

    repo.query!(
      """
      INSERT INTO automation_job_runs(tenant_id,id,automation_job_id,event,status,finished_at,inserted_at,updated_at)
      VALUES($1::text::uuid,9101,9100,'{}','succeeded',now(),now(),now())
      """,
      [tenant]
    )

    repo.query!(
      """
      INSERT INTO signal_bindings(tenant_id,id,name,adapter,config_ref,routing_mode,
        automation_job_id,target,enabled,inserted_at,updated_at)
      VALUES($1::text::uuid,$2::text::uuid,'Retained Applet source','internal',
        'applet://' || $3,'action',9100,'{}',true,now(),now())
      """,
      [tenant, retained_binding, page]
    )

    repo.query!(
      """
      INSERT INTO signal_binding_receipts(tenant_id,binding_id,source,source_event_id,signal_id,automation_job_run_id)
      VALUES($1::text::uuid,$2::text::uuid,'ankole:applet:retained','retained-event','retained-event',9101)
      """,
      [tenant, retained_binding]
    )

    Ecto.Migrator.run(repo, Ankole.Migrations.paths(), :up, all: true, log: false)

    assert [[9100]] ==
             repo.query!(
               "SELECT id FROM automation_jobs WHERE tenant_id=$1::text::uuid AND id IN (9000,9100)",
               [tenant]
             ).rows

    assert [[0]] ==
             repo.query!(
               "SELECT count(*) FROM automation_job_runs WHERE tenant_id=$1::text::uuid AND automation_job_id=9000",
               [tenant]
             ).rows

    assert [[0]] ==
             repo.query!(
               "SELECT count(*) FROM signal_bindings WHERE tenant_id=$1::text::uuid AND (automation_job_id=9000 OR config_ref='job://9000')",
               [tenant]
             ).rows

    assert [[0]] ==
             repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_name='automation_jobs' AND column_name IN ('executor_kind','agent_uid','drive_prefix','owner_session_id')"
             ).rows

    assert [[2, 1, 1]] ==
             repo.query!(
               "SELECT count(*),count(automation_job_run_id),count(delivered_signal_id) FROM signal_binding_receipts WHERE tenant_id=$1::text::uuid",
               [tenant]
             ).rows

    assert [["action", 9100, 9101]] ==
             repo.query!(
               """
               SELECT b.routing_mode,b.automation_job_id,r.automation_job_run_id
               FROM signal_bindings b JOIN signal_binding_receipts r
                 ON r.tenant_id=b.tenant_id AND r.binding_id=b.id
               JOIN automation_job_runs j ON j.tenant_id=r.tenant_id AND j.id=r.automation_job_run_id
               WHERE b.tenant_id=$1::text::uuid AND b.id=$2::text::uuid
               """,
               [tenant, retained_binding]
             ).rows

    assert [["migration-agent", signal]] ==
             repo.query!(
               """
               SELECT s.agent_uid,e.signal_id::text FROM scheduled_events e
               JOIN signals s ON s.tenant_id=e.tenant_id AND s.id=e.signal_id
               JOIN agents a ON a.tenant_id=s.tenant_id AND a.uid=s.agent_uid
               WHERE e.tenant_id=$1::text::uuid AND e.id=9004
               """,
               [tenant]
             ).rows

    Repo.with_tenant(tenant, fn ->
      {:ok, event} = Ankole.Schedule.get_checkback(9004)
      projection = Ankole.Schedule.Projections.event_model_projection(event)

      assert [%{automation_job_run_id: nil, delivered_signal_id: ^signal}] =
               projection["deliveries"]

      assert :ok = Ankole.Signals.Dispatch.expire_receipts(DateTime.utc_now())
      assert length(Ankole.Signals.delivery_receipts(signal)) == 1
    end)

    repo.query!(
      "UPDATE principals SET uid='migration-owner-renamed' WHERE tenant_id=$1::text::uuid AND uid='migration-owner'",
      [tenant]
    )

    assert [["migration-owner-renamed"]] ==
             repo.query!(
               "SELECT owner_uid FROM pages WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
               [tenant, page]
             ).rows

    :verified
  end)

IO.puts(
  "Signal/Action migration verified: historical routing conversion, Agent-script retirement, preserved Applet and Agent delivery history, retention, and owner rename."
)
