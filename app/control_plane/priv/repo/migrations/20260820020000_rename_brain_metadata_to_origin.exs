defmodule Ankole.Repo.Migrations.RenameBrainMetadataToOrigin do
  @moduledoc false

  use Ecto.Migration

  # Data-only: renames the persisted conversation-scope-declaration key from
  # the retired Brain module's name ("brain") to its replacement
  # ("origin"), and drops the "visibility" field that only Brain's
  # memory-store routing needed. See
  # `Ankole.SignalsGateway.AIGatewayLink.conversation_origin/2` and
  # `initial_origin_metadata/1` for the shape this produces going forward.
  def up do
    execute("""
    UPDATE ai_gateway_conversations
    SET metadata = (metadata - 'brain') ||
      CASE
        WHEN (metadata->'brain') - 'visibility' = '{}'::jsonb THEN '{}'::jsonb
        ELSE jsonb_build_object('origin', (metadata->'brain') - 'visibility')
      END
    WHERE metadata ? 'brain'
    """)

    execute("""
    UPDATE background_agent_jobs
    SET metadata = jsonb_set(
      metadata - 'brain_owner_conversation_id',
      '{owner_conversation_id}',
      metadata->'brain_owner_conversation_id'
    )
    WHERE metadata ? 'brain_owner_conversation_id'
    """)
  end

  # Best effort: the trimmed "visibility" value is not recoverable, so a
  # restored "brain" object gets a visibility inferred from which fields are
  # present ("peer_uid" -> dm, "channel_id" -> shared, neither -> self). A
  # conversation whose origin was already empty (the undeclared case) is left
  # alone rather than guessing it back into existence.
  def down do
    execute("""
    UPDATE background_agent_jobs
    SET metadata = jsonb_set(
      metadata - 'owner_conversation_id',
      '{brain_owner_conversation_id}',
      metadata->'owner_conversation_id'
    )
    WHERE metadata ? 'owner_conversation_id'
    """)

    execute("""
    UPDATE ai_gateway_conversations
    SET metadata = (metadata - 'origin') ||
      jsonb_build_object(
        'brain',
        (metadata->'origin') ||
        jsonb_build_object(
          'visibility',
          CASE
            WHEN metadata->'origin' ? 'peer_uid' THEN 'dm'
            WHEN metadata->'origin' ? 'channel_id' THEN 'shared'
            ELSE 'self'
          END
        )
      )
    WHERE metadata ? 'origin'
    """)
  end
end
