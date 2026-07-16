defmodule Ankole.Repo.Migrations.AddDeepResearchRuntime do
  use Ecto.Migration

  def up do
    alter table(:subagent_delegations) do
      add :mode, :text

      add :source_delegation_id,
          references(:subagent_delegations, type: :uuid, on_delete: :restrict)

      add :actual_outcome, :boolean
    end

    create index(:subagent_delegations, [:source_delegation_id],
             name: :subagent_delegations_source_index,
             where: "source_delegation_id IS NOT NULL"
           )

    drop constraint(:subagent_delegations, :subagent_delegations_runtime_check)

    create constraint(:subagent_delegations, :subagent_delegations_runtime_check,
             check: "runtime IN ('task_worker', 'deep_research')"
           )

    create constraint(:subagent_delegations, :subagent_delegations_research_contract_check,
             check: """
             (runtime = 'task_worker' AND mode IS NULL AND source_delegation_id IS NULL AND actual_outcome IS NULL)
             OR
             (runtime = 'deep_research' AND mode IN ('general', 'forecast', 'retrospect') AND
               ((mode = 'retrospect' AND source_delegation_id IS NOT NULL) OR
                (mode <> 'retrospect' AND source_delegation_id IS NULL AND actual_outcome IS NULL)))
             """
           )

    alter table(:actor_events) do
      add :final_response_id, :text
      add :turn_outcome, :text
    end

    create constraint(:actor_events, :actor_events_turn_outcome_check,
             check:
               "turn_outcome IS NULL OR turn_outcome IN ('loop_finished', 'iteration_exhausted')"
           )

    create constraint(:actor_events, :actor_events_completion_anchor_check,
             check: """
             (final_response_id IS NULL AND turn_outcome IS NULL) OR
             (final_response_id IS NOT NULL AND final_response_id LIKE 'resp_%' AND
              turn_outcome IS NOT NULL AND completed_at IS NOT NULL)
             """
           )
  end

  def down do
    drop constraint(:actor_events, :actor_events_completion_anchor_check)
    drop constraint(:actor_events, :actor_events_turn_outcome_check)

    alter table(:actor_events) do
      remove :turn_outcome
      remove :final_response_id
    end

    drop constraint(:subagent_delegations, :subagent_delegations_research_contract_check)
    drop constraint(:subagent_delegations, :subagent_delegations_runtime_check)

    create constraint(:subagent_delegations, :subagent_delegations_runtime_check,
             check: "runtime IN ('task_worker')"
           )

    drop index(:subagent_delegations, [:source_delegation_id],
           name: :subagent_delegations_source_index
         )

    alter table(:subagent_delegations) do
      remove :actual_outcome
      remove :source_delegation_id
      remove :mode
    end
  end
end
