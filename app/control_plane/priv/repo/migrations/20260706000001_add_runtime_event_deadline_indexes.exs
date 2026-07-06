defmodule Ankole.Repo.Migrations.AddRuntimeEventDeadlineIndexes do
  use Ecto.Migration

  def up do
    create index(:actor_session_activations, [:status, :lease_expires_at],
             name: :actor_session_activations_status_lease_deadline_index,
             where: "status IN ('starting', 'active', 'draining')"
           )

    create index(:agent_computer_workers, [:status, :last_worker_heartbeat_at],
             name: :agent_computer_workers_status_heartbeat_deadline_index,
             where: "status IN ('ready', 'draining')"
           )

    create index(:agent_computer_workers, [:status, :stopped_at],
             name: :agent_computer_workers_status_stopped_deadline_index,
             where: "status IN ('stale', 'stopped')"
           )

    create index(:ai_gateway_messages, [:status, :type, :updated_at],
             name: :ai_gateway_messages_generating_deadline_index,
             where: "status = 'generating' AND type = 'message'"
           )

    execute("""
    CREATE INDEX codex_delegations_running_worker_route_index
    ON codex_delegations ((metadata->>'worker_route'))
    WHERE status IN ('running', 'waiting_on_user')
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS codex_delegations_running_worker_route_index")

    drop_if_exists index(:ai_gateway_messages, [:status, :type, :updated_at],
                     name: :ai_gateway_messages_generating_deadline_index
                   )

    drop_if_exists index(:agent_computer_workers, [:status, :stopped_at],
                     name: :agent_computer_workers_status_stopped_deadline_index
                   )

    drop_if_exists index(:agent_computer_workers, [:status, :last_worker_heartbeat_at],
                     name: :agent_computer_workers_status_heartbeat_deadline_index
                   )

    drop_if_exists index(:actor_session_activations, [:status, :lease_expires_at],
                     name: :actor_session_activations_status_lease_deadline_index
                   )
  end
end
