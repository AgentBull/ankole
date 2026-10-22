defmodule Ankole.Repo.Migrations.ScopeTenantForeignKeys do
  use Ecto.Migration

  @parent_keys [
    {:ai_gateway_conversations, :id},
    {:ai_gateway_messages, :id},
    {:automation_job_runs, :id},
    {:automation_jobs, :id},
    {:background_agent_job_turns, :id},
    {:background_agent_jobs, :id},
    {:brain_objects, :id},
    {:brain_sources, :id},
    {:cron_schedules, :id},
    {:human_users, :principal_uid},
    {:oidc_clients, :id},
    {:oidc_sessions, :id},
    {:workflow_runs, :id}
  ]

  # RotateOidcCredentialStorage owns the session and family keys of OIDC
  # authorization codes and refresh tokens.
  @foreign_keys [
    {:agent_library_container_entries, :agent_library_container_entries_agent_uid_fkey,
     :agent_uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:agent_plugin_overrides, :agent_plugin_overrides_agent_uid_fkey, :agent_uid, :principals,
     :uid, "CASCADE", "NO ACTION"},
    {:agent_skill_lessons, :agent_skill_lessons_agent_uid_fkey, :agent_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:agent_skills, :agent_skills_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:agents, :agents_owner_principal_uid_fkey, :owner_principal_uid, :principals, :uid,
     "RESTRICT", "NO ACTION"},
    {:agents, :agents_uid_fkey, :uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:ai_gateway_artifacts, :ai_gateway_artifacts_message_id_fkey, :message_id,
     :ai_gateway_messages, :id, "CASCADE", "NO ACTION"},
    {:ai_gateway_artifacts, :ai_gateway_artifacts_subject_uid_fkey, :subject_uid, :principals,
     :uid, "CASCADE", "NO ACTION"},
    {:ai_gateway_compaction_artifacts, :ai_gateway_compaction_artifacts_conversation_id_fkey,
     :conversation_id, :ai_gateway_conversations, :id, "CASCADE", "NO ACTION"},
    {:ai_gateway_compaction_artifacts, :ai_gateway_compaction_artifacts_subject_uid_fkey,
     :subject_uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:ai_gateway_conversations, :ai_gateway_conversations_subject_uid_fkey, :subject_uid,
     :principals, :uid, "CASCADE", "NO ACTION"},
    {:ai_gateway_messages, :ai_gateway_messages_conversation_id_fkey, :conversation_id,
     :ai_gateway_conversations, :id, "CASCADE", "NO ACTION"},
    {:ai_gateway_messages, :ai_gateway_messages_previous_message_id_fkey, :previous_message_id,
     :ai_gateway_messages, :id, "SET NULL", "NO ACTION"},
    {:ai_gateway_messages, :ai_gateway_messages_subject_uid_fkey, :subject_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:ai_gateway_usage_records, :ai_gateway_usage_records_subject_uid_fkey, :subject_uid,
     :principals, :uid, "CASCADE", "NO ACTION"},
    {:automation_job_runs, :automation_job_runs_automation_job_id_fkey, :automation_job_id,
     :automation_jobs, :id, "CASCADE", "NO ACTION"},
    {:automation_jobs, :automation_jobs_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:automation_jobs, :automation_jobs_source_signal_id_fkey, :source_signal_id, :signals, :id,
     "SET NULL", "NO ACTION"},
    {:background_agent_job_turn_items, :background_agent_job_turn_items_turn_id_fkey, :turn_id,
     :background_agent_job_turns, :id, "CASCADE", "NO ACTION"},
    {:background_agent_job_turns, :background_agent_job_turns_job_id_fkey, :job_id,
     :background_agent_jobs, :id, "CASCADE", "NO ACTION"},
    {:background_agent_jobs, :background_agent_jobs_agent_uid_fkey, :agent_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:background_agent_jobs, :background_agent_jobs_continued_from_job_id_fkey,
     :continued_from_job_id, :background_agent_jobs, :id, "RESTRICT", "NO ACTION"},
    {:background_agent_jobs, :background_agent_jobs_source_signal_id_fkey, :source_signal_id,
     :signals, :id, "SET NULL", "NO ACTION"},
    {:background_agent_jobs, :background_agent_jobs_workspace_owner_job_id_fkey,
     :workspace_owner_job_id, :background_agent_jobs, :id, "RESTRICT", "NO ACTION"},
    {:brain_chunks, :brain_chunks_object_id_fkey, :object_id, :brain_objects, :id, "CASCADE",
     "NO ACTION"},
    {:brain_claims, :brain_claims_consolidated_into_fkey, :consolidated_into, :brain_claims, :id,
     "NO ACTION", "NO ACTION"},
    {:brain_claims, :brain_claims_superseded_by_fkey, :superseded_by, :brain_claims, :id,
     "NO ACTION", "NO ACTION"},
    {:brain_contradictions, :brain_contradictions_a_claim_id_fkey, :a_claim_id, :brain_claims,
     :id, "CASCADE", "NO ACTION"},
    {:brain_contradictions, :brain_contradictions_b_claim_id_fkey, :b_claim_id, :brain_claims,
     :id, "CASCADE", "NO ACTION"},
    {:brain_object_versions, :brain_object_versions_object_id_fkey, :object_id, :brain_objects,
     :id, "CASCADE", "NO ACTION"},
    {:brain_objects, :brain_objects_managed_by_source_id_fkey, :managed_by_source_id,
     :brain_sources, :id, "SET NULL", "NO ACTION"},
    {:browser_pod_authentications, :browser_pod_authentications_principal_uid_fkey,
     :principal_uid, :human_users, :principal_uid, "NO ACTION", "NO ACTION"},
    {:conversation_inbound_batches, :conversation_inbound_batches_agent_uid_fkey, :agent_uid,
     :principals, :uid, "CASCADE", "NO ACTION"},
    {:cron_schedules, :cron_schedules_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:cron_schedules, :cron_schedules_automation_job_id_fkey, :automation_job_id,
     :automation_jobs, :id, "RESTRICT", "NO ACTION"},
    {:deliveries, :deliveries_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:drive_files, :agent_files_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:human_access_events, :human_access_events_principal_uid_fkey, :principal_uid, :human_users,
     :principal_uid, "NO ACTION", "NO ACTION"},
    {:human_access_restrictions, :human_access_restrictions_principal_uid_fkey, :principal_uid,
     :human_users, :principal_uid, "NO ACTION", "NO ACTION"},
    {:human_user_local_credentials, :human_user_local_credentials_principal_uid_fkey,
     :principal_uid, :human_users, :principal_uid, "CASCADE", "NO ACTION"},
    {:human_users, :human_users_principal_uid_fkey, :principal_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:oidc_authorization_codes, :oidc_authorization_codes_client_id_fkey, :client_id,
     :oidc_clients, :id, "CASCADE", "NO ACTION"},
    {:oidc_authorization_codes, :oidc_authorization_codes_principal_uid_fkey, :principal_uid,
     :principals, :uid, "CASCADE", "NO ACTION"},
    {:oidc_client_groups, :oidc_client_groups_client_id_fkey, :client_id, :oidc_clients, :id,
     "CASCADE", "NO ACTION"},
    {:oidc_client_groups, :oidc_client_groups_group_id_fkey, :group_id, :principal_groups, :id,
     "CASCADE", "NO ACTION"},
    {:oidc_logout_deliveries, :oidc_logout_deliveries_session_id_fkey, :session_id,
     :oidc_sessions, :id, "CASCADE", "NO ACTION"},
    {:oidc_logout_requests, :oidc_logout_requests_client_id_fkey, :client_id, :oidc_clients, :id,
     "CASCADE", "NO ACTION"},
    {:oidc_refresh_token_families, :oidc_refresh_token_families_session_id_fkey, :session_id,
     :oidc_sessions, :id, "CASCADE", "NO ACTION"},
    {:oidc_refresh_tokens, :oidc_refresh_tokens_client_id_fkey, :client_id, :oidc_clients, :id,
     "CASCADE", "NO ACTION"},
    {:oidc_refresh_tokens, :oidc_refresh_tokens_principal_uid_fkey, :principal_uid, :principals,
     :uid, "CASCADE", "NO ACTION"},
    {:oidc_sessions, :oidc_sessions_client_id_fkey, :client_id, :oidc_clients, :id, "CASCADE",
     "NO ACTION"},
    {:oidc_sessions, :oidc_sessions_principal_uid_fkey, :principal_uid, :human_users,
     :principal_uid, "NO ACTION", "NO ACTION"},
    {:permission_grants, :permission_grants_group_id_fkey, :group_id, :principal_groups, :id,
     "CASCADE", "NO ACTION"},
    {:permission_grants, :permission_grants_principal_uid_fkey, :principal_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:principal_external_identities, :principal_external_identities_principal_uid_fkey,
     :principal_uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:principal_group_external_bindings, :principal_group_external_bindings_group_id_fkey,
     :group_id, :principal_groups, :id, "CASCADE", "NO ACTION"},
    {:principal_group_memberships, :principal_group_memberships_group_id_fkey, :group_id,
     :principal_groups, :id, "CASCADE", "NO ACTION"},
    {:principal_group_memberships, :principal_group_memberships_principal_uid_fkey,
     :principal_uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:scheduled_events, :scheduled_events_agent_uid_fkey, :agent_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:scheduled_events, :scheduled_events_automation_job_id_fkey, :automation_job_id,
     :automation_jobs, :id, "RESTRICT", "NO ACTION"},
    {:scheduled_events, :scheduled_events_automation_job_run_id_fkey, :automation_job_run_id,
     :automation_job_runs, :id, "SET NULL", "NO ACTION"},
    {:scheduled_events, :scheduled_events_cron_schedule_id_fkey, :cron_schedule_id,
     :cron_schedules, :id, "SET NULL", "NO ACTION"},
    {:scheduled_events, :scheduled_events_origin_ai_message_id_fkey, :origin_ai_message_id,
     :ai_gateway_messages, :id, "SET NULL", "NO ACTION"},
    {:scheduled_events, :scheduled_events_signal_id_fkey, :signal_id, :signals, :id, "SET NULL",
     "NO ACTION"},
    {:scheduled_events, :scheduled_events_source_signal_id_fkey, :source_signal_id, :signals, :id,
     "SET NULL", "NO ACTION"},
    {:session_ambient_judgments, :session_ambient_judgments_agent_uid_fkey, :agent_uid,
     :principals, :uid, "CASCADE", "NO ACTION"},
    {:session_ambient_judgments, :session_ambient_judgments_signal_id_fkey, :signal_id, :signals,
     :id, "CASCADE", "NO ACTION"},
    {:session_round_states, :session_round_states_message_id_fkey, :message_id,
     :ai_gateway_messages, :id, "CASCADE", "NO ACTION"},
    {:session_tool_receipts, :session_tool_receipts_agent_uid_fkey, :agent_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:sessions, :sessions_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:signal_bindings, :signal_bindings_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:signal_webhook_endpoints, :signal_webhook_endpoints_agent_uid_fkey, :agent_uid, :principals,
     :uid, "CASCADE", "NO ACTION"},
    {:signal_webhook_endpoints, :signal_webhook_endpoints_automation_job_id_fkey,
     :automation_job_id, :automation_jobs, :id, "RESTRICT", "NO ACTION"},
    {:signal_webhook_endpoints, :signal_webhook_endpoints_source_signal_id_fkey,
     :source_signal_id, :signals, :id, "SET NULL", "NO ACTION"},
    {:signals, :signals_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE", "NO ACTION"},
    {:workflow_agent_calls, :workflow_agent_calls_agent_uid_fkey, :agent_uid, :principals, :uid,
     "CASCADE", "NO ACTION"},
    {:workflow_agent_calls, :workflow_agent_calls_run_id_fkey, :run_id, :workflow_runs, :id,
     "CASCADE", "NO ACTION"},
    {:workflow_runs, :workflow_runs_agent_uid_fkey, :agent_uid, :principals, :uid, "CASCADE",
     "NO ACTION"},
    {:workflow_runs, :workflow_runs_source_signal_id_fkey, :source_signal_id, :signals, :id,
     "SET NULL", "NO ACTION"}
  ]

  def up do
    for {table, column} <- @parent_keys,
        do: create(unique_index(table, [:tenant_id, column]))

    for key <- @foreign_keys, do: replace_foreign_key(key, true)
  end

  def down do
    for key <- @foreign_keys, do: replace_foreign_key(key, false)

    for {table, column} <- Enum.reverse(@parent_keys),
        do: drop(index(table, [:tenant_id, column]))
  end

  defp replace_foreign_key(
         {table, name, column, parent, parent_column, on_delete, on_update},
         scoped?
       ) do
    columns = if scoped?, do: "tenant_id, #{column}", else: to_string(column)
    parent_columns = if scoped?, do: "tenant_id, #{parent_column}", else: to_string(parent_column)

    on_delete =
      if scoped? and on_delete == "SET NULL",
        do: "SET NULL (#{column})",
        else: on_delete

    execute("ALTER TABLE #{table} DROP CONSTRAINT #{name}")

    execute(
      "ALTER TABLE #{table} ADD CONSTRAINT #{name} " <>
        "FOREIGN KEY (#{columns}) REFERENCES #{parent} (#{parent_columns}) " <>
        "ON DELETE #{on_delete} ON UPDATE #{on_update}"
    )
  end
end
