defmodule Ankole.Repo.Migrations.AddReplyCardkitState do
  use Ecto.Migration

  def change do
    alter table(:actor_events) do
      add :reply_preview_checkpoint, :map
      add :reply_preview_sequence_high_water, :bigint, null: false, default: 0
      add :reply_preview_cleanup_at, :utc_datetime_usec
    end

    create index(:actor_events, [:reply_preview_cleanup_at],
             where: "reply_preview_cleanup_at IS NOT NULL"
           )

    create index(:actor_events, [:completed_at],
             name: :actor_events_recoverable_reply_preview_index,
             where: "reply_preview_checkpoint IS NOT NULL"
           )

    create constraint(:actor_events, :actor_events_reply_preview_checkpoint_object,
             check:
               "reply_preview_checkpoint IS NULL OR jsonb_typeof(reply_preview_checkpoint) = 'object'"
           )

    create constraint(:actor_events, :actor_events_reply_preview_sequence_non_negative,
             check: "reply_preview_sequence_high_water >= 0"
           )
  end
end
