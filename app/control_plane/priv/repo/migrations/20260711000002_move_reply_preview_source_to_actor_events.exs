defmodule Ankole.Repo.Migrations.MoveReplyPreviewSourceToActorEvents do
  use Ecto.Migration

  def up do
    alter table(:actor_events) do
      add :reply_preview_source_entry_id, :text
    end

    execute("""
    UPDATE actor_events AS actor_event
    SET reply_preview_source_entry_id = message.metadata->>'preview_source_entry_id'
    FROM ai_gateway_messages AS message
    WHERE message.metadata->>'actor_event_id' = actor_event.id::text
      AND coalesce(message.metadata->>'preview_source_entry_id', '') <> ''
      AND actor_event.reply_preview_source_entry_id IS NULL
    """)

    execute(
      "COMMENT ON COLUMN actor_events.reply_preview_source_entry_id IS 'Provider entry created for the live AI reply preview; SignalsGateway uses it as the final edit target.'"
    )
  end

  def down do
    alter table(:actor_events) do
      remove :reply_preview_source_entry_id
    end
  end
end
