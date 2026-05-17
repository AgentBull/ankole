defmodule BullX.Repo.Migrations.AddCommandTargetType do
  use Ecto.Migration

  def up do
    execute("ALTER TYPE eventbus_target_type ADD VALUE IF NOT EXISTS 'command'")

    alter table(:event_routing_rules) do
      modify :target_ref, :text, from: :uuid
    end

    alter table(:target_sessions) do
      modify :target_ref, :text, from: :uuid
    end

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'event_routing_rules_target_ref_trimmed'
          AND conrelid = 'event_routing_rules'::regclass
      ) THEN
        ALTER TABLE event_routing_rules
          ADD CONSTRAINT event_routing_rules_target_ref_trimmed
          CHECK (
            target_type = 'blackhole' OR
            (target_ref = btrim(target_ref) AND target_ref <> '')
          );
      END IF;
    END
    $$;
    """)
  end

  def down do
    drop constraint(:event_routing_rules, :event_routing_rules_target_ref_trimmed)

    alter table(:target_sessions) do
      modify :target_ref, :uuid, from: :text
    end

    alter table(:event_routing_rules) do
      modify :target_ref, :uuid, from: :text
    end
  end
end
