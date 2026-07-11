defmodule Ankole.Repo.Migrations.DecoupleAIGatewayFromActor do
  use Ecto.Migration

  def up do
    drop_if_exists index(:ai_gateway_messages, [],
                     name: :ai_gateway_messages_generating_actor_event_index
                   )

    rename table(:ai_gateway_conversations), :agent_uid, to: :subject_uid
    rename table(:ai_gateway_messages), :agent_uid, to: :subject_uid
    rename table(:ai_gateway_compaction_artifacts), :agent_uid, to: :subject_uid

    rename_constraint(
      :ai_gateway_conversations,
      :ai_gateway_conversations_agent_uid_fkey,
      :ai_gateway_conversations_subject_uid_fkey
    )

    rename_constraint(
      :ai_gateway_messages,
      :ai_gateway_messages_agent_uid_fkey,
      :ai_gateway_messages_subject_uid_fkey
    )

    rename_constraint(
      :ai_gateway_compaction_artifacts,
      :ai_gateway_compaction_artifacts_agent_uid_fkey,
      :ai_gateway_compaction_artifacts_subject_uid_fkey
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_conversations.subject_uid IS 'Principal that owns the conversation.'"
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_messages.subject_uid IS 'Principal that owns the response message.'"
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_compaction_artifacts.subject_uid IS 'Principal that owns the compaction artifact.'"
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_messages.metadata IS 'Opaque caller metadata plus AIGateway response facts.'"
    )

    execute(
      "COMMENT ON TABLE ai_gateway_conversations IS 'Durable AIGateway conversation threads per Principal subject.'"
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_conversations.conversation_key IS 'Subject-local key used to identify an active conversation.'"
    )

    execute(
      "COMMENT ON TABLE ai_gateway_messages IS 'Stored Response, journal, and checkpoint facts owned by AIGateway.'"
    )

    execute(
      "COMMENT ON TABLE ai_gateway_compaction_artifacts IS 'Immutable compaction artifacts owned by an AIGateway subject.'"
    )
  end

  def down do
    rename_constraint(
      :ai_gateway_compaction_artifacts,
      :ai_gateway_compaction_artifacts_subject_uid_fkey,
      :ai_gateway_compaction_artifacts_agent_uid_fkey
    )

    rename_constraint(
      :ai_gateway_messages,
      :ai_gateway_messages_subject_uid_fkey,
      :ai_gateway_messages_agent_uid_fkey
    )

    rename_constraint(
      :ai_gateway_conversations,
      :ai_gateway_conversations_subject_uid_fkey,
      :ai_gateway_conversations_agent_uid_fkey
    )

    rename table(:ai_gateway_compaction_artifacts), :subject_uid, to: :agent_uid
    rename table(:ai_gateway_messages), :subject_uid, to: :agent_uid
    rename table(:ai_gateway_conversations), :subject_uid, to: :agent_uid

    execute(
      "COMMENT ON TABLE ai_gateway_conversations IS 'Durable AI-gateway conversation threads per agent.'"
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_conversations.conversation_key IS 'Agent-local key used to identify the active conversation lane.'"
    )

    execute("""
    CREATE UNIQUE INDEX ai_gateway_messages_generating_actor_event_index
    ON ai_gateway_messages ((metadata->>'actor_event_id'))
    WHERE status = 'generating' AND type = 'message'
    """)
  end

  defp rename_constraint(table, from, to) do
    execute("ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to}")
  end
end
