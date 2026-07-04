defmodule Ankole.Repo.Migrations.CreatePrincipalsAndAuth do
  # 基础身份与授权层。
  #
  # 这一组迁移建立 Ankole 安装级的所有权主体与权限模型：
  #   - principals / human_users / agents           身份三件套（统一 uid 主键）
  #   - principal_external_identities               外部平台身份绑定
  #   - principal_groups / memberships / bindings   授权分组
  #   - permission_grants                           资源-动作授权
  #
  # Principal uid 是全安装范围的小写主键（见 AGENTS.md「Principal/AuthZ」约定），
  # 所有引用它的外键都用 references(:principals, column: :uid, type: :text)。
  use Ecto.Migration

  def change do
    # ── 枚举类型 ──────────────────────────────────────────────
    execute(
      "CREATE TYPE principal_type AS ENUM ('human', 'agent')",
      "DROP TYPE principal_type"
    )

    execute(
      "CREATE TYPE principal_status AS ENUM ('active', 'disabled')",
      "DROP TYPE principal_status"
    )

    execute(
      "CREATE TYPE agent_type AS ENUM ('ai_colleague')",
      "DROP TYPE agent_type"
    )

    execute(
      """
      CREATE TYPE principal_external_identity_kind AS ENUM (
        'platform_subject',
        'channel_actor',
        'login_subject',
        'outbound_actor'
      )
      """,
      "DROP TYPE principal_external_identity_kind"
    )

    execute(
      "CREATE TYPE principal_group_kind AS ENUM ('static', 'computed')",
      "DROP TYPE principal_group_kind"
    )

    # ── principals：一切主体的小写 uid 主键 ───────────────────
    create table(:principals, primary_key: false) do
      add :uid, :text, primary_key: true
      add :type, :principal_type, null: false
      add :status, :principal_status, null: false, default: "active"
      add :display_name, :text
      add :avatar_url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:principals, :principals_uid_present, check: "length(btrim(uid)) > 0")

    create constraint(:principals, :principals_uid_lowercase, check: "uid = lower(uid)")

    comment_table(:principals, "Canonical actors that can own state or receive authorization.")

    comment_columns(:principals, %{
      uid: "Stable lowercase principal identifier shared by humans and agents.",
      type: "Principal subtype used to route to the matching profile table.",
      status: "Lifecycle state used to disable access without deleting history.",
      display_name: "Operator-visible name for UI and audit surfaces.",
      avatar_url: "Optional avatar image URL for UI rendering."
    })

    # ── human_users：人类主体扩展字段 ─────────────────────────
    create table(:human_users, primary_key: false) do
      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :email, :text
      add :mobile, :text
      add :job_title, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_users, [:email],
             name: :human_users_email_index,
             where: "email IS NOT NULL"
           )

    create unique_index(:human_users, [:mobile],
             name: :human_users_mobile_index,
             where: "mobile IS NOT NULL"
           )

    comment_table(:human_users, "Human-only profile fields for principals of type human.")

    comment_columns(:human_users, %{
      principal_uid: "Principal uid this human profile extends.",
      email: "Optional human email address used for contact and login binding.",
      mobile: "Optional phone number used for contact and external identity binding.",
      job_title: "Operator-visible role or title for the human."
    })

    # ── agents：AI 代理主体扩展字段 ───────────────────────────
    create table(:agents, primary_key: false) do
      add :uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :type, :agent_type, null: false, default: "ai_colleague"
      add :role, :text, null: false
      add :options, :map, null: false, default: %{}

      add :created_by_principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agents, [:created_by_principal_uid])

    # 加速「哪些 agent 用到了某个 provider」的反查（GIN on jsonb path）。
    execute(
      """
      CREATE INDEX agents_ai_agent_model_provider_ids_index
      ON agents
      USING gin (
        (jsonb_path_query_array(options, 'lax $.ai_agent.models.*.provider_id'::jsonpath))
        jsonb_path_ops
      )
      """,
      "DROP INDEX agents_ai_agent_model_provider_ids_index"
    )

    create constraint(:agents, :agents_role_present, check: "length(btrim(role)) > 0")

    create constraint(:agents, :agents_options_object, check: "jsonb_typeof(options) = 'object'")

    comment_table(:agents, "Agent-only profile fields for principals that run work.")

    comment_columns(:agents, %{
      uid: "Principal uid this agent profile extends.",
      type: "Agent subtype; currently all runtime agents are AI colleagues.",
      role: "Human-authored role statement used to frame the agent identity.",
      options: "Agent profile options that are not modeled as first-class columns.",
      created_by_principal_uid: "Human or agent principal that created this agent."
    })

    # ── principal_external_identities：外部身份绑定 ──────────
    create table(:principal_external_identities, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :kind, :principal_external_identity_kind, null: false
      add :provider, :text
      add :adapter, :text
      add :channel_id, :text
      add :external_id, :text
      add :verified_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:principal_external_identities, [:principal_uid])

    create unique_index(
             :principal_external_identities,
             [:adapter, :channel_id, :external_id],
             name: :principal_external_identities_channel_actor_index,
             where: "kind = 'channel_actor'"
           )

    create unique_index(
             :principal_external_identities,
             [:kind, :provider, :external_id],
             name: :principal_external_identities_provider_identity_index,
             where: "kind <> 'channel_actor'"
           )

    # channel_actor 形状与非 channel_actor 形状互斥：一组字段必填另一组必空。
    create constraint(
             :principal_external_identities,
             :principal_external_identities_shape,
             check: """
             (
               kind = 'channel_actor'
               AND provider IS NULL
               AND adapter IS NOT NULL
               AND channel_id IS NOT NULL
               AND external_id IS NOT NULL
             )
             OR
             (
               kind <> 'channel_actor'
               AND provider IS NOT NULL
               AND adapter IS NULL
               AND channel_id IS NULL
               AND external_id IS NOT NULL
             )
             """
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_provider_format,
             check: "provider IS NULL OR provider ~ '^[a-z][a-z0-9_-]*$'"
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :principal_external_identities,
      "External identity bindings that connect principals to providers, channels, and login subjects."
    )

    comment_columns(:principal_external_identities, %{
      principal_uid: "Principal represented by this external identity.",
      kind: "Identity shape: platform subject, channel actor, login subject, or outbound actor.",
      provider: "Provider namespace for non-channel identities.",
      adapter: "SignalsGateway adapter namespace for channel actor identities.",
      channel_id: "Provider channel id when the identity belongs to a channel actor.",
      external_id: "Provider supplied subject or actor identifier.",
      verified_at: "Time this identity binding was last proven by the provider.",
      metadata: "Provider-specific identity facts kept outside the stable contract."
    })

    # ── principal_groups：授权分组 ────────────────────────────
    create table(:principal_groups, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :display_name, :text, null: false
      add :kind, :principal_group_kind, null: false, default: "static"
      add :built_in, :boolean, null: false, default: false
      add :computed_condition, :text
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:principal_groups, [:name])

    create constraint(:principal_groups, :principal_groups_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(:principal_groups, :principal_groups_name_lowercase,
             check: "name = lower(name)"
           )

    create constraint(:principal_groups, :principal_groups_display_name_present,
             check: "length(btrim(display_name)) > 0"
           )

    # static 组不能有 computed_condition；computed 组必须有非空 condition。
    create constraint(:principal_groups, :principal_groups_computed_condition_by_kind,
             check: """
             (
               kind = 'static'
               AND computed_condition IS NULL
             )
             OR
             (
               kind = 'computed'
               AND computed_condition IS NOT NULL
               AND length(btrim(computed_condition)) > 0
             )
             """
           )

    create constraint(:principal_groups, :principal_groups_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:principal_groups, "Authorization groups that collect principals for grants.")

    comment_columns(:principal_groups, %{
      name: "Stable lowercase group name used by policy code and operators.",
      display_name: "Human-readable group name for console and audit views.",
      kind: "Whether membership is explicitly stored or computed from a condition.",
      built_in: "Marks groups created by Ankole rather than by an operator.",
      computed_condition: "Condition expression that defines computed membership.",
      description: "Operator-facing explanation of the group purpose.",
      metadata: "Group metadata that is useful but not part of authorization matching."
    })

    # ── principal_group_memberships：静态组成员 ───────────────
    create table(:principal_group_memberships, primary_key: false) do
      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :group_id,
          references(:principal_groups, type: :uuid, on_delete: :delete_all),
          primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:principal_group_memberships, [:group_id])

    comment_table(:principal_group_memberships, "Explicit static group memberships.")

    comment_columns(:principal_group_memberships, %{
      principal_uid: "Principal that belongs to the group.",
      group_id: "Group receiving the principal membership."
    })

    # ── principal_group_external_bindings：外部分组绑定 ──────
    create table(:principal_group_external_bindings, primary_key: false) do
      add :provider, :text, primary_key: true
      add :external_id, :text, primary_key: true

      add :group_id,
          references(:principal_groups, type: :uuid, on_delete: :delete_all),
          null: false

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:principal_group_external_bindings, [:group_id])

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_provider_present,
             check: "length(btrim(provider)) > 0"
           )

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_provider_format,
             check: "provider ~ '^[a-z][a-z0-9_-]*$'"
           )

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_external_id_present,
             check: "length(btrim(external_id)) > 0"
           )

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :principal_group_external_bindings,
      "Provider group bindings that synchronize or imply Ankole group membership."
    )

    comment_columns(:principal_group_external_bindings, %{
      provider: "External provider namespace for the group binding.",
      external_id: "Provider supplied group identifier.",
      group_id: "Ankole authorization group represented by the external group.",
      metadata: "Provider-specific binding facts kept outside the stable contract."
    })

    # ── permission_grants：资源-动作授权 ──────────────────────
    create table(:permission_grants, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all)

      add :group_id, references(:principal_groups, type: :uuid, on_delete: :delete_all)
      add :resource_pattern, :text, null: false
      add :action, :text, null: false
      add :condition, :text, null: false, default: "true"
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:permission_grants, [:principal_uid, :action])
    create index(:permission_grants, [:group_id, :action])

    create unique_index(
             :permission_grants,
             [:principal_uid, :resource_pattern, :action, :condition],
             name: :permission_grants_principal_natural_index,
             where: "principal_uid IS NOT NULL"
           )

    create unique_index(
             :permission_grants,
             [:group_id, :resource_pattern, :action, :condition],
             name: :permission_grants_group_natural_index,
             where: "group_id IS NOT NULL"
           )

    # 一条 grant 必须归属且仅归属一个主体：principal 或 group，二选一。
    create constraint(:permission_grants, :permission_grants_owner_shape,
             check: """
             (
               principal_uid IS NOT NULL
               AND group_id IS NULL
             )
             OR
             (
               principal_uid IS NULL
               AND group_id IS NOT NULL
             )
             """
           )

    create constraint(:permission_grants, :permission_grants_resource_pattern_present,
             check: "length(btrim(resource_pattern)) > 0"
           )

    create constraint(:permission_grants, :permission_grants_action_present,
             check: "length(btrim(action)) > 0"
           )

    # action 不允许含冒号——冒号是 resource:action 分隔符，混入会破坏解析。
    create constraint(:permission_grants, :permission_grants_action_no_colon,
             check: "position(':' in action) = 0"
           )

    create constraint(:permission_grants, :permission_grants_condition_present,
             check: "length(btrim(condition)) > 0"
           )

    create constraint(:permission_grants, :permission_grants_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:permission_grants, "Principal or group grants over resource patterns.")

    comment_columns(:permission_grants, %{
      principal_uid: "Direct principal owner of the grant when the grant is not group-based.",
      group_id: "Group owner of the grant when the grant is not direct to a principal.",
      resource_pattern: "Resource pattern matched by the authorization engine.",
      action: "Action name allowed by this grant.",
      condition: "Condition expression that must evaluate true for the grant to apply.",
      description: "Operator-facing explanation of why the grant exists.",
      metadata: "Grant metadata that is not evaluated by the authorization engine."
    })
  end

  # ── COMMENT 辅助函数：给表/列写文档注释 ───────────────────
  # 用 execute 正反向，确保 down 时能清理。identifier 做标识符转义防注入。

  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}",
      "COMMENT ON TABLE #{identifier(table)} IS NULL"
    )
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute(
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}",
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS NULL"
    )
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
