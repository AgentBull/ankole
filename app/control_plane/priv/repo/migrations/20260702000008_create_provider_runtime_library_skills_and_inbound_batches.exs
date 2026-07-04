defmodule Ankole.Repo.Migrations.CreateProviderRuntimeLibrarySkillsAndInboundBatches do
  # 收尾子系统：AI Gateway provider 连接、agent library、skill 注册表与 overlay、
  # 以及 IM 入站批量去重表。
  #
  # 注意：
  #   - signal_gateway_inbound_batches 暂时保留。当 new-plan.md §2.3 的
  #     「inbound batch finalize 不由 ReadyInputProcessor 触发」在代码中落地后，
  #     再连同 schema/inbound_batches.ex/测试一起删除。
  use Ecto.Migration

  def up do
    # ══ AI Gateway provider 运行时 ══════════════════════════════

    create table(:ai_gateway_providers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_id, :text, null: false
      add :provider_kind, :text, null: false
      add :base_url, :text
      add :encrypted_options, :map, null: false, default: %{}
      add :connection_options, :map, null: false, default: %{}
      add :disabled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:ai_gateway_providers, :ai_gateway_providers_provider_id_format,
             check: "provider_id ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_provider_kind_format,
             check: "provider_kind ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_base_url_present,
             check: "base_url IS NULL OR base_url <> ''"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_connection_options_object,
             check: "jsonb_typeof(connection_options) = 'object'"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_encrypted_options_object,
             check: "jsonb_typeof(encrypted_options) = 'object'"
           )

    create unique_index(:ai_gateway_providers, [:provider_id],
             name: :ai_gateway_providers_provider_id_index
           )

    create index(:ai_gateway_providers, [:provider_kind],
             name: :ai_gateway_providers_provider_kind_index
           )

    create index(:ai_gateway_providers, [:provider_id],
             name: :ai_gateway_providers_active_index,
             where: "disabled_at IS NULL"
           )

    comment_table(:ai_gateway_providers, "Operator-managed AIGateway provider connections.")

    comment_columns(:ai_gateway_providers, %{
      id: "Opaque UUIDv7 row id used as the provider encrypted option context.",
      provider_id: "Stable operator-facing provider id referenced by model profiles.",
      provider_kind: "Provider kind module id such as OpenRouter, OpenAI, Claude, or Jina.",
      base_url: "Optional provider API base URL override.",
      encrypted_options: "Encrypted provider-kind-specific options stored by the control plane.",
      connection_options:
        "Provider-kind-specific connection options used during runtime resolution.",
      disabled_at: "Time the provider was disabled and excluded from runtime resolution."
    })

    # ══ Agent library：persona docs 与文件内容 ═════════════════
    # 存 agent 拥有的 persona/setting 文件（SOUL.md / MISSION.md / SETTING.md 等）。
    # skill overlay 不在这里——它们在 agent_skill_overlays 表。
    create table(:agent_library_container_entries, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :path, :text, null: false
      add :source_kind, :text, null: false
      add :content, :text
      add :content_hash, :text
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_library_container_entries, [:agent_uid, :path],
             name: :agent_library_container_entries_active_path_index,
             where: "deleted_at IS NULL"
           )

    create index(:agent_library_container_entries, [:agent_uid, :source_kind],
             name: :agent_library_container_entries_source_kind_index
           )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_path_present,
             check: "length(btrim(path)) > 0"
           )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_source_kind_check,
             check:
               "source_kind IN ('soul', 'mission', 'setting', 'memory', 'system', 'user', 'computer')"
           )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :agent_library_container_entries,
      "Per-agent library container entries materialized for worker-visible files."
    )

    comment_columns(:agent_library_container_entries, %{
      agent_uid: "Agent principal that owns the library entry.",
      path: "Agent-local library path exposed to the worker.",
      source_kind: "Library source bucket such as mission, memory, system, or computer.",
      content: "Text content stored for file-backed library entries.",
      content_hash: "Hash of the stored content projection.",
      metadata: "Library entry metadata outside the file content contract.",
      deleted_at: "Soft-delete marker that removes the path from the active library view."
    })

    # ══ library_builtin_sync_state：builtin 内容同步游标 ════════
    create table(:library_builtin_sync_state, primary_key: false) do
      add :name, :text, primary_key: true
      add :content_hash, :text, null: false
      add :synced_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:library_builtin_sync_state, :library_builtin_sync_state_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(
             :library_builtin_sync_state,
             :library_builtin_sync_state_content_hash_present,
             check: "length(btrim(content_hash)) > 0"
           )

    create constraint(:library_builtin_sync_state, :library_builtin_sync_state_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:library_builtin_sync_state, "Sync checkpoints for built-in library content.")

    comment_columns(:library_builtin_sync_state, %{
      name: "Built-in content bundle or source name.",
      content_hash: "Hash last observed for the built-in content source.",
      synced_at: "Time the built-in content source was last synchronized.",
      metadata: "Sync metadata outside the content hash contract."
    })

    # ══ agent_skill_overlays：per-agent skill overlay ═══════════
    # 与 agent_skills 配合：agent_skills 是注册表元数据，
    # overlay 是叠加到 SKILL.md 上的定制 JSON。
    create table(:agent_skill_overlays, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:skill_name, :text, null: false)

      add(:overlay_json, :map, null: false, default: %{})
      add(:content_hash, :text, null: false)
      add(:deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:agent_skill_overlays, [:agent_uid, :skill_name],
        name: :agent_skill_overlays_active_skill_index,
        where: "deleted_at IS NULL"
      )
    )

    create(
      constraint(:agent_skill_overlays, :agent_skill_overlays_skill_name_format,
        check: "skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    create(
      constraint(:agent_skill_overlays, :agent_skill_overlays_overlay_object,
        check: "jsonb_typeof(overlay_json) = 'object'"
      )
    )

    create(
      constraint(:agent_skill_overlays, :agent_skill_overlays_content_hash_present,
        check: "length(btrim(content_hash)) > 0"
      )
    )

    comment_table(
      :agent_skill_overlays,
      "Per-agent skill overlay documents authored after built-in sync."
    )

    comment_columns(:agent_skill_overlays, %{
      agent_uid: "Agent principal that owns the overlay.",
      skill_name: "Skill whose overlay is being customized.",
      overlay_json: "Structured overlay content applied on top of the base skill.",
      content_hash: "Hash of the overlay JSON projection.",
      deleted_at: "Soft-delete marker that removes the overlay from the active skill view."
    })

    # ══ agent_skills：skill 注册表 ══════════════════════════════
    create table(:agent_skills, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:skill_name, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:relative_path, :text, null: false)
      add(:enabled, :boolean, null: false)
      add(:default_enabled, :boolean, null: false)
      add(:description, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:content_hash, :text, null: false)
      add(:synced_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:agent_skills, [:agent_uid, :skill_name],
        name: :agent_skills_agent_skill_index
      )
    )

    create(index(:agent_skills, [:agent_uid, :enabled], name: :agent_skills_agent_enabled_index))

    create(
      constraint(:agent_skills, :agent_skills_skill_name_format,
        check: "skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_source_kind_check,
        check: "source_kind IN ('builtin', 'installed')"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_relative_path_present,
        check: "length(btrim(relative_path)) > 0"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_description_present,
        check: "length(btrim(description)) > 0"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_metadata_object,
        check: "jsonb_typeof(metadata) = 'object'"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_content_hash_present,
        check: "length(btrim(content_hash)) > 0"
      )
    )

    comment_table(:agent_skills, "Per-agent skill registry used by runtime skill discovery.")

    comment_columns(:agent_skills, %{
      agent_uid: "Agent principal that owns the skill registry row.",
      skill_name: "Agent-visible skill name.",
      source_kind: "Whether the skill comes from built-in repository content or installed files.",
      relative_path: "Path to the skill entrypoint relative to its source root.",
      enabled: "Whether the skill is currently enabled for the agent.",
      default_enabled: "Default enablement from the source before agent overrides.",
      description: "Short skill description shown to operators and workers.",
      metadata: "Skill metadata outside the discovery contract.",
      content_hash: "Hash of the skill entrypoint or synchronized source projection.",
      synced_at: "Time this registry row was last synchronized from its source."
    })

    # ══ signal_gateway_inbound_batches：IM 入站批量去重 ═════════
    # 暂时保留。当 new-plan.md §2.3 移除意图在代码中落地后删除。
    create table(:signal_gateway_inbound_batches, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :binding_name, :text, null: false
      add :session_id, :text, null: false

      add :signal_channel_id,
          references(:signal_channels, column: :id, type: :text, on_delete: :delete_all),
          null: false

      add :provider_thread_id, :text, null: false, default: ""
      add :batch_state, :text, null: false, default: "open"
      add :mode, :text, null: false, default: "neutral"
      add :policy, :text, null: false
      add :requester_sender_key, :text
      add :entries, :map, null: false, default: fragment("'[]'::jsonb")
      add :available_at, :utc_datetime_usec, null: false
      add :hard_cap_at, :utc_datetime_usec
      add :batch_revision, :integer, null: false, default: 0
      add :outcome, :text
      add :finalized_at, :utc_datetime_usec
      # Phase 1：actor_input_id → actor_event_id。
      add :actor_event_id, :uuid

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :signal_gateway_inbound_batches,
             [:agent_uid, :binding_name, :signal_channel_id, :provider_thread_id],
             where: "batch_state = 'open'",
             name: :signal_gateway_inbound_batches_open_index
           )

    create index(:signal_gateway_inbound_batches, [:batch_state, :available_at],
             name: :signal_gateway_inbound_batches_due_index
           )

    create index(
             :signal_gateway_inbound_batches,
             [:agent_uid, :binding_name, :signal_channel_id],
             name: :signal_gateway_inbound_batches_entry_lookup_index
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_entries_array,
             check: "jsonb_typeof(entries) = 'array'"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_state_check,
             check: "batch_state IN ('open', 'finalized', 'canceled')"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_mode_check,
             check: "mode IN ('neutral', 'addressed')"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_policy_check,
             check: "policy IN ('ignore', 'record_only', 'may_intervene')"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_outcome_check,
             check:
               "outcome IS NULL OR outcome IN ('addressed', 'ambient', 'no_actor_input', 'duplicate_consumed', 'canceled')"
           )
  end

  def down do
    drop table(:signal_gateway_inbound_batches)
    drop table(:agent_skills)
    drop table(:agent_skill_overlays)
    drop table(:library_builtin_sync_state)
    drop table(:agent_library_container_entries)
    drop table(:ai_gateway_providers)
  end

  defp comment_table(table, comment) do
    execute("COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}")
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute("COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}")
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
