defmodule Ankole.Repo.Migrations.IdentifySignalBindings do
  use Ecto.Migration

  def up do
    alter table(:signal_bindings) do
      add :id, :uuid
      add :routing_mode, :text, null: false, default: "ai_colleague"
    end

    flush()

    for [tenant, uid, name] <-
          repo().query!("SELECT tenant_id, agent_uid, name FROM signal_bindings").rows do
      id = Ankole.Kernel.gen_uuid_v7() |> Ecto.UUID.dump!()

      repo().query!(
        "UPDATE signal_bindings SET id=$1 WHERE tenant_id=$2 AND agent_uid=$3 AND name=$4",
        [id, tenant, uid, name]
      )
    end

    execute(
      "ALTER TABLE signal_bindings DROP CONSTRAINT signal_bindings_pkey, ALTER COLUMN id SET NOT NULL, ALTER COLUMN agent_uid DROP NOT NULL, ADD PRIMARY KEY(id)"
    )

    drop index(:signal_bindings, [:tenant_id, :agent_uid, :name],
           name: :signal_bindings_tenant_route_index
         )

    create unique_index(:signal_bindings, [:tenant_id, :id])

    create unique_index(:signal_bindings, [:tenant_id, :agent_uid, :name],
             name: :signal_bindings_agent_name_index
           )

    create unique_index(:signal_bindings, [:tenant_id, :name],
             where: "routing_mode = 'sender_personal_assistant'",
             name: :signal_bindings_shared_name_index
           )

    create constraint(:signal_bindings, :signal_bindings_routing_target,
             check:
               "(routing_mode = 'ai_colleague' AND agent_uid IS NOT NULL) OR (routing_mode = 'sender_personal_assistant' AND agent_uid IS NULL AND adapter IN ('lark', 'slack') AND unmatched_sender_policy = 'manual_review')"
           )

    for {table, column} <- [
          {:signals, :reply_binding_id},
          {:deliveries, :binding_id},
          {:conversation_inbound_batches, :binding_id}
        ] do
      alter table(table) do
        add column, :uuid
      end
    end

    flush()

    for {table, column, name} <- [
          {"signals", "reply_binding_id", "reply_binding_name"},
          {"deliveries", "binding_id", "binding_name"},
          {"conversation_inbound_batches", "binding_id", "binding_name"}
        ] do
      execute(
        "UPDATE #{table} r SET #{column}=b.id FROM signal_bindings b WHERE r.tenant_id=b.tenant_id AND r.agent_uid=b.agent_uid AND r.#{name}=b.name"
      )

      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_#{column}_fkey FOREIGN KEY(tenant_id,#{column}) REFERENCES signal_bindings(tenant_id,id) ON DELETE SET NULL (#{column})"
      )
    end

    execute("""
    UPDATE principal_groups g SET name='signal_source:' || b.id::text,
      metadata=jsonb_set(g.metadata, '{signals,binding_id}', to_jsonb(b.id::text))
    FROM signal_bindings b
    WHERE g.tenant_id=b.tenant_id AND g.domain='signal_source'
      AND g.name=lower('signal_source:' || b.agent_uid || ':' || b.name);
    """)

    execute("""
    UPDATE principal_groups g SET metadata=jsonb_set(g.metadata, '{signals,binding_memberships}', (
      SELECT jsonb_object_agg(COALESCE(b.id::text, member.key),
        CASE WHEN b.id IS NULL THEN member.value ELSE member.value || jsonb_build_object('binding_id',b.id) END)
      FROM jsonb_each(g.metadata#>'{signals,binding_memberships}') member
      LEFT JOIN signal_bindings b ON b.tenant_id=g.tenant_id
        AND b.agent_uid=member.value->>'agent_uid' AND b.name=member.value->>'binding_name'
    ))
    WHERE jsonb_typeof(g.metadata#>'{signals,binding_memberships}')='object'
      AND g.metadata#>'{signals,binding_memberships}' <> '{}'::jsonb;
    """)

    execute("""
    UPDATE oban_jobs j SET args=(j.args - 'agent_uid' - 'binding_name') || jsonb_build_object('binding_id',b.id)
    FROM signal_bindings b
    WHERE j.args->>'tenant_id'=b.tenant_id::text AND j.args->>'agent_uid'=b.agent_uid
      AND j.args->>'binding_name'=b.name
      AND j.worker IN (
        'Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups', 'Ankole.Plugins.LarkAdapter.Jobs.RefreshIMGroup',
        'Ankole.Plugins.SlackAdapter.Jobs.SyncChannels', 'Ankole.Plugins.SlackAdapter.Jobs.RefreshChannel',
        'Ankole.Plugins.Microsoft365Adapter.Jobs.SyncChannels', 'Ankole.Plugins.Microsoft365Adapter.Jobs.RefreshChannel');
    """)

    for table <- ["background_agent_jobs", "workflow_runs", "automation_jobs"] do
      execute(
        "UPDATE #{table} w SET reply_route=w.reply_route || jsonb_build_object('binding_id',b.id) FROM signal_bindings b WHERE w.tenant_id=b.tenant_id AND w.agent_uid=b.agent_uid AND w.reply_route->>'binding_name'=b.name"
      )
    end

    execute("""
    UPDATE cron_schedules w SET delivery=jsonb_set(w.delivery,'{targets}', (
      SELECT jsonb_agg(CASE WHEN b.id IS NULL THEN t.target ELSE t.target || jsonb_build_object('binding_id',b.id) END ORDER BY t.ordinal)
      FROM jsonb_array_elements(w.delivery->'targets') WITH ORDINALITY t(target,ordinal)
      LEFT JOIN signal_bindings b ON b.tenant_id=w.tenant_id AND b.agent_uid=w.agent_uid AND b.name=t.target->>'binding_name'
    )) WHERE jsonb_typeof(w.delivery->'targets')='array' AND w.delivery->'targets' <> '[]'::jsonb;
    """)
  end

  def down do
    raise "Shared signal bindings require their own identity"
  end
end
