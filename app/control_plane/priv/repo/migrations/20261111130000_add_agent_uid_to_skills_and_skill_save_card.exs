defmodule Ankole.Repo.Migrations.AddAgentUidToSkillsAndSkillSaveCard do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE skills
      ADD COLUMN agent_uid text,
      ADD CONSTRAINT skills_agent_uid_fkey
        FOREIGN KEY (tenant_id, agent_uid) REFERENCES agents(tenant_id, uid)
        ON UPDATE CASCADE ON DELETE CASCADE,
      ADD CONSTRAINT skills_private_shape
        CHECK (agent_uid IS NULL OR (source_kind = 'custom' AND NOT enabled_for_all))
    """)

    execute("""
    CREATE INDEX skills_agent_uid_idx
      ON skills (tenant_id, agent_uid)
      WHERE agent_uid IS NOT NULL
    """)

    execute("""
    ALTER TABLE conversation_action_cards
      DROP CONSTRAINT conversation_action_cards_action_kind_check
    """)

    execute("""
    ALTER TABLE conversation_action_cards
      ADD CONSTRAINT conversation_action_cards_action_kind_check
      CHECK (action_kind IN (
        'brain.object.create',
        'pod.knowledge.save',
        'pod.page.set_sharing',
        'pod.page.delete',
        'pod.page.restore',
        'pod.base.delete_table',
        'conversation.add_participants',
        'library.skill.save'
      ))
    """)
  end

  def down do
    raise "Personal skills and skill action cards contain durable content; restore a database backup to reverse this migration"
  end
end
