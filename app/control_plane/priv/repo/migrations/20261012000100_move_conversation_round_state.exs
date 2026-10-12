defmodule Ankole.Repo.Migrations.MoveConversationRoundState do
  use Ecto.Migration

  def up do
    create table(:conversation_round_states, primary_key: false) do
      add :message_id, references(:ai_gateway_messages, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false
      add :iteration, :integer, null: false, default: 0
      add :steer_event_ids, {:array, :uuid}, null: false, default: []
      add :nudged, :boolean, null: false, default: false
      add :repaired, :boolean, null: false, default: false
      add :repair_failure, :text
      add :workflow_attempt, :integer
      add :truncated_rounds, :integer, null: false, default: 0
      add :outcome, :text, null: false, default: "loop_finished"
      add :pages, :map, null: false, default: %{}
      add :results, :map, null: false, default: %{}
    end

    create index(:conversation_round_states, [:tenant_id])

    create constraint(:conversation_round_states, :conversation_round_states_outcome,
             check:
               "outcome IN ('loop_finished', 'iteration_exhausted', 'silent', 'stopped', 'dead_letter', 'sleeping', 'submitted', 'requeued')"
           )

    execute """
    INSERT INTO conversation_round_states
      (message_id, tenant_id, iteration, steer_event_ids, nudged, repaired,
       repair_failure, workflow_attempt, truncated_rounds, outcome, pages, results)
    SELECT id, tenant_id,
      COALESCE((metadata #>> '{request_metadata,loop,iteration}')::integer, 0),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(metadata #> '{request_metadata,loop,steer_event_ids}', '[]'::jsonb))::uuid),
      COALESCE((metadata #>> '{request_metadata,loop,nudged}')::boolean, false),
      COALESCE((metadata #>> '{request_metadata,loop,repaired}')::boolean, false),
      metadata #>> '{request_metadata,loop,repair_failure}',
      (metadata #>> '{request_metadata,loop,workflow_attempt}')::integer,
      COALESCE((metadata #>> '{request_metadata,loop,truncated_rounds}')::integer, 0),
      COALESCE(metadata #>> '{request_metadata,loop,outcome}', 'loop_finished'),
      COALESCE(metadata #> '{request_metadata,loop,pages}', '{}'::jsonb),
      COALESCE(metadata #> '{request_metadata,loop,results}', '{}'::jsonb)
    FROM ai_gateway_messages WHERE metadata #> '{request_metadata,loop}' IS NOT NULL
    """

    execute """
    UPDATE ai_gateway_messages
    SET metadata = (metadata #- '{request_metadata,loop}') #- '{request_metadata,model_profile}'
      || CASE WHEN metadata #>> '{request_metadata,model_profile}' IS NOT NULL
        THEN jsonb_build_object('model_profile', metadata #>> '{request_metadata,model_profile}')
        ELSE '{}'::jsonb END
    WHERE metadata #> '{request_metadata,loop}' IS NOT NULL
       OR metadata #> '{request_metadata,model_profile}' IS NOT NULL
    """
  end

  def down do
    execute """
    UPDATE ai_gateway_messages m
    SET metadata = jsonb_set(m.metadata, '{request_metadata,loop}', to_jsonb(s) - 'tenant_id' - 'message_id')
    FROM conversation_round_states s WHERE s.message_id = m.id
    """

    drop table(:conversation_round_states)
  end
end
