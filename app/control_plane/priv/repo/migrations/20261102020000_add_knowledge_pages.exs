defmodule Ankole.Repo.Migrations.AddKnowledgePages do
  use Ecto.Migration

  def up do
    alter table(:drive_nodes) do
      add :system_key, :text
    end

    create unique_index(:drive_nodes, [:tenant_id, :system_key],
             where: "system_key IS NOT NULL",
             name: :drive_nodes_system_key_index
           )

    drop constraint(:drive_nodes, :drive_nodes_kind)

    create constraint(:drive_nodes, :drive_nodes_kind,
             check: "kind IN ('folder','file','doc','knowledge','base','applet')"
           )

    alter table(:pages) do
      add :metadata, :map, null: false, default: %{}
      add :upstream_state, :map, null: false, default: %{}
    end

    alter table(:page_snapshots) do
      add :metadata, :map, null: false, default: %{}
    end

    create constraint(:pages, :pages_metadata_object, check: "jsonb_typeof(metadata) = 'object'")

    create constraint(:pages, :pages_upstream_state_object,
             check: "jsonb_typeof(upstream_state) = 'object'"
           )

    drop constraint(:conversation_action_cards, :conversation_action_cards_action_kind_check)

    create constraint(:conversation_action_cards, :conversation_action_cards_action_kind_check,
             check:
               "action_kind IN ('pod.knowledge.save','pod.page.set_sharing','pod.page.delete','pod.page.restore','pod.base.delete_table','conversation.add_participants')"
           )

    execute """
    CREATE OR REPLACE VIEW pod_page_nodes AS
    SELECT n.tenant_id,n.id,n.parent_id,n.private_owner_uid,n.kind AS type,
      CASE WHEN n.kind IN ('folder','file') THEN n.name ELSE COALESCE(p.title,'') END AS title,
      p.icon,p.position,n.inherit_permissions,n.has_local_acl,n.is_acl_anchor,n.acl_anchor_id,n.parent_anchor_id,
      COALESCE(p.revision,0) AS revision,p.saved_from_message_id,COALESCE(p.children_view,'{}'::jsonb) AS children_view,
      n.created_by,n.deleted_at,n.purge_started_at,n.created_at,GREATEST(n.updated_at,p.updated_at) AS updated_at,
      n.name,n.conversation_id,n.object_id,(n.parent_id IS NULL) AS is_root,
      COALESCE(p.metadata,'{}'::jsonb) AS metadata,COALESCE(p.upstream_state,'{}'::jsonb) AS upstream_state,n.system_key
    FROM drive_nodes n LEFT JOIN pages p ON p.tenant_id=n.tenant_id AND p.id=n.id
    """
  end

  def down do
    raise "Knowledge pages contain durable content; restore a database backup to reverse this migration"
  end
end
