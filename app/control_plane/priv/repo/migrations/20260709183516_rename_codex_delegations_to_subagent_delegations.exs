defmodule Ankole.Repo.Migrations.RenameCodexDelegationsToSubagentDelegations do
  use Ecto.Migration

  def up do
    rename table(:codex_delegations), to: table(:subagent_delegations)
    rename table(:codex_delegation_events), to: table(:subagent_delegation_events)
    rename table(:subagent_delegations), :codex_thread_id, to: :runtime_thread_id

    alter table(:subagent_delegations) do
      add :runtime, :text, null: false, default: "codex"
      add :title, :text
      add :prompt, :text
      add :reply_route, :map, null: false, default: %{}
      add :attempts, :integer, null: false, default: 0
    end

    execute("""
    UPDATE subagent_delegations AS delegation
    SET reply_route = jsonb_strip_nulls(jsonb_build_object(
      'binding_name', actor_event.binding_name,
      'signal_channel_id', actor_event.signal_channel_id,
      'provider_thread_id', actor_event.provider_thread_id,
      'source_entry_id', actor_event.source_entry_id
    ))
    FROM actor_events AS actor_event
    WHERE delegation.actor_event_id = actor_event.id
    """)

    rename_constraints_and_indexes(:up)

    create constraint(:subagent_delegations, :subagent_delegations_runtime_check,
             check: "runtime IN ('codex')"
           )

    create constraint(:subagent_delegations, :subagent_delegations_reply_route_object,
             check: "jsonb_typeof(reply_route) = 'object'"
           )

    create constraint(:subagent_delegations, :subagent_delegations_attempts_nonnegative,
             check: "attempts >= 0"
           )

    execute("""
    CREATE INDEX subagent_delegations_agent_status_queued_index
    ON subagent_delegations (agent_uid, status, queued_at DESC)
    """)

    execute("""
    CREATE INDEX subagent_delegations_agent_channel_queued_index
    ON subagent_delegations (agent_uid, (reply_route->>'signal_channel_id'), queued_at DESC)
    """)

    create unique_index(:subagent_delegations, [:agent_uid, :session_id, :tool_call_id],
             name: :subagent_delegations_parent_tool_call_index,
             where: "tool_call_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:subagent_delegations, [:agent_uid, :session_id, :tool_call_id],
                     name: :subagent_delegations_parent_tool_call_index
                   )

    execute("DROP INDEX IF EXISTS subagent_delegations_agent_channel_queued_index")
    execute("DROP INDEX IF EXISTS subagent_delegations_agent_status_queued_index")

    drop constraint(:subagent_delegations, :subagent_delegations_attempts_nonnegative)
    drop constraint(:subagent_delegations, :subagent_delegations_reply_route_object)
    drop constraint(:subagent_delegations, :subagent_delegations_runtime_check)

    rename_constraints_and_indexes(:down)

    alter table(:subagent_delegations) do
      remove :attempts
      remove :reply_route
      remove :prompt
      remove :title
      remove :runtime
    end

    rename table(:subagent_delegations), :runtime_thread_id, to: :codex_thread_id
    rename table(:subagent_delegation_events), to: table(:codex_delegation_events)
    rename table(:subagent_delegations), to: table(:codex_delegations)
  end

  defp rename_constraints_and_indexes(direction) do
    names = [
      {:constraint, "codex_delegations_pkey", "subagent_delegations_pkey"},
      {:constraint, "codex_delegations_agent_uid_fkey", "subagent_delegations_agent_uid_fkey"},
      {:constraint, "codex_delegations_actor_event_id_fkey",
       "subagent_delegations_actor_event_id_fkey"},
      {:constraint, "codex_delegations_status_check", "subagent_delegations_status_check"},
      {:constraint, "codex_delegations_result_object", "subagent_delegations_result_object"},
      {:constraint, "codex_delegations_error_object", "subagent_delegations_error_object"},
      {:constraint, "codex_delegations_metadata_object", "subagent_delegations_metadata_object"},
      {:constraint, "codex_delegation_events_pkey", "subagent_delegation_events_pkey"},
      {:constraint, "codex_delegation_events_delegation_id_fkey",
       "subagent_delegation_events_delegation_id_fkey"},
      {:constraint, "codex_delegation_events_agent_uid_fkey",
       "subagent_delegation_events_agent_uid_fkey"},
      {:constraint, "codex_delegation_events_direction_check",
       "subagent_delegation_events_direction_check"},
      {:constraint, "codex_delegation_events_payload_object",
       "subagent_delegation_events_payload_object"},
      {:constraint, "codex_delegation_events_redaction_object",
       "subagent_delegation_events_redaction_object"},
      {:index, "codex_delegations_agent_session_index",
       "subagent_delegations_agent_session_index"},
      {:index, "codex_delegations_agent_status_index", "subagent_delegations_agent_status_index"},
      {:index, "codex_delegations_running_worker_route_index",
       "subagent_delegations_running_worker_route_index"},
      {:index, "codex_delegation_events_delegation_seq_index",
       "subagent_delegation_events_delegation_seq_index"},
      {:index, "codex_delegation_events_agent_inserted_index",
       "subagent_delegation_events_agent_inserted_index"}
    ]

    Enum.each(names, fn {kind, old_name, new_name} ->
      {from, to} = if direction == :up, do: {old_name, new_name}, else: {new_name, old_name}

      case kind do
        :constraint ->
          table =
            if String.contains?(from, "delegation_events"),
              do: "subagent_delegation_events",
              else: "subagent_delegations"

          execute("ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to}")

        :index ->
          execute("ALTER INDEX #{from} RENAME TO #{to}")
      end
    end)
  end
end
