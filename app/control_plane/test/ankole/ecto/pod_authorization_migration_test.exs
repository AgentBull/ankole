defmodule Ankole.Ecto.PodAuthorizationMigrationTest do
  use Ankole.DataCase, async: false

  @migration Ankole.Repo.Migrations.UnifyPodAuthorization
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261023100600_unify_pod_authorization.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "pod_authz_upgrade_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}, public")

    for sql <- [
          "CREATE TABLE principals (uid text PRIMARY KEY, tenant_id uuid NOT NULL, type text NOT NULL)",
          "CREATE TABLE principal_groups (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, name text, built_in boolean, kind text, computed_condition text)",
          """
          CREATE TABLE pages (
            id uuid PRIMARY KEY, tenant_id uuid NOT NULL, parent_id uuid, private_owner_uid text,
            inherit_permissions boolean NOT NULL DEFAULT true, deleted_at timestamptz,
            title text NOT NULL DEFAULT '', icon text, type text NOT NULL DEFAULT 'doc',
            position text COLLATE "C" NOT NULL DEFAULT 'a', updated_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE (tenant_id, id))
          """,
          """
          CREATE TABLE permission_grants (
            id uuid PRIMARY KEY, tenant_id uuid NOT NULL, principal_uid text, group_id uuid,
            resource_pattern text NOT NULL, action text NOT NULL, condition text NOT NULL DEFAULT 'true',
            description text, metadata jsonb NOT NULL DEFAULT '{}',
            inserted_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
            CONSTRAINT permission_grants_owner_shape CHECK (num_nonnulls(principal_uid, group_id) = 1))
          """,
          "CREATE UNIQUE INDEX permission_grants_principal_natural_index ON permission_grants (tenant_id, principal_uid, resource_pattern, action, condition) WHERE principal_uid IS NOT NULL",
          "CREATE UNIQUE INDEX permission_grants_group_natural_index ON permission_grants (tenant_id, group_id, resource_pattern, action, condition) WHERE group_id IS NOT NULL"
        ],
        do: Repo.query!(sql)

    tenant_id = Ecto.UUID.generate()
    root = Ecto.UUID.generate()
    child = Ecto.UUID.generate()
    leaf = Ecto.UUID.generate()
    trash = Ecto.UUID.generate()
    group = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO principals VALUES ('human', $1::text::uuid, 'human'), ('agent', $1::text::uuid, 'agent'), ('system', $1::text::uuid, 'system')",
      [tenant_id]
    )

    Repo.query!(
      "INSERT INTO principal_groups VALUES ($1::text::uuid, $2::text::uuid, 'all_humans', true, 'computed', 'principal.type == \"human\"')",
      [group, tenant_id]
    )

    for {id, parent, deleted} <- [
          {root, nil, false},
          {child, root, false},
          {leaf, child, false},
          {trash, leaf, true}
        ] do
      Repo.query!(
        "INSERT INTO pages (id, tenant_id, parent_id, deleted_at) VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid, CASE WHEN $4 THEN now() END)",
        [id, tenant_id, parent, deleted]
      )
    end

    {:ok, tenant_id: tenant_id, root: root, child: child, leaf: leaf, trash: trash, group: group}
  end

  test "upgrade closes namespaces, merges duplicate owners, and backfills Page boundaries", ctx do
    for {pattern, action} <- [
          {"**", "read"},
          {"tenant_console:**", "read"},
          {"*", "delete"},
          {"pod:space", "update"},
          {"site:tenants", "read"},
          {"app_configuration:*", "read"},
          {"worker_provider:*", "read"},
          {"principal:*", "update"},
          {"pod:**:#{ctx.child}:page", "page_view"},
          {"pod:**:#{Ecto.UUID.generate()}:**", "page_view"}
        ],
        do: grant(ctx, pattern, action)

    grant(ctx, "**", "update", "true", :group)
    grant(ctx, "tenant_console:**", "update", "true", :group)
    run_migration()

    patterns =
      Repo.query!("SELECT resource_pattern FROM permission_grants ORDER BY resource_pattern").rows
      |> List.flatten()

    assert Enum.sort(patterns) ==
             Enum.sort([
               "site_console:**",
               "tenant_console:**",
               "site_console:*",
               "tenant_console:*",
               "tenant_console:pod_space",
               "site_console:tenants",
               "site_console:app_configuration:*",
               "site_console:worker_provider:*",
               "site_console:principal:*",
               "pod:**:#{ctx.child}:page",
               "site_console:**",
               "tenant_console:**"
             ])

    assert Repo.query!(
             "SELECT count(*) FROM permission_grants WHERE resource_pattern NOT LIKE 'pod:%' AND substring(id::text, 15, 1) <> '7'"
           ).rows == [[2]]

    assert Repo.query!("SELECT type,membership FROM principals ORDER BY type").rows == [
             ["agent", nil],
             ["human", "member"],
             ["system", nil]
           ]

    assert Repo.query!("SELECT computed_condition FROM principal_groups").rows == [
             [
               ~s(principal.type == "human" && principal.membership == "member" && principal.status == "active")
             ]
           ]

    assert Repo.query!(
             "SELECT target_page_id::text,target_scope FROM permission_grants WHERE action='page_view'"
           ).rows == [[ctx.child, "self"]]

    assert anchors() ==
             Map.new([
               {ctx.root, [true, ctx.root, nil, false]},
               {ctx.child, [true, ctx.child, ctx.root, true]},
               {ctx.leaf, [false, ctx.child, nil, false]},
               {ctx.trash, [true, ctx.trash, ctx.child, false]}
             ])

    assert Repo.query!(
             "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname IN ('pages_tenant_parent_tree_index','pages_parent_position_covering_index','pages_title_trgm_gin_index')"
           ).rows == [[3]]
  end

  test "migration refuses conditions with the resource free variable before rewriting grants",
       ctx do
    id = grant(ctx, "principal:*", "read", ~s(resource == "principal:alice"))
    error = assert_raise RuntimeError, fn -> run_migration() end
    assert error.message =~ id
    assert error.message =~ "principal:*"
    assert Repo.query!("SELECT resource_pattern FROM permission_grants").rows == [["principal:*"]]
  end

  test "migration preserves runtime and unknown grants with resource conditions", ctx do
    for {pattern, action} <- [
          {"agent:runtime", "chat"},
          {"agent:runtime:tool:*", "invoke"},
          {"agent:runtime:tool:pod.read", "invoke"},
          {"agent:runtime:custom", "read"},
          {"vendor:resource", "update"},
          {"principal:runtime", "invoke"},
          {"site_console:principal:*", "read"},
          {"tenant_console:pod_space", "update"}
        ],
        condition <- ["true", ~s|resource.startsWith("#{hd(String.split(pattern, ":"))}:")|] do
      grant(ctx, pattern, action, condition)
    end

    select =
      "SELECT id,tenant_id,principal_uid,group_id,resource_pattern,action,condition,description,metadata,inserted_at,updated_at FROM permission_grants ORDER BY id"

    before = Repo.query!(select).rows
    run_migration()
    assert Repo.query!(select).rows == before
  end

  test "migration distinguishes legacy Agent administration actions from runtime actions", ctx do
    for action <- ~w(read update delete chat), do: grant(ctx, "agent:legacy", action)
    grant(ctx, "agent:legacy:tool:*", "invoke")
    run_migration()

    assert Repo.query!(
             "SELECT resource_pattern,action FROM permission_grants ORDER BY resource_pattern,action"
           ).rows == [
             ["agent:legacy", "chat"],
             ["agent:legacy:tool:*", "invoke"],
             ["site_console:agent:legacy", "delete"],
             ["site_console:agent:legacy", "read"],
             ["site_console:agent:legacy", "update"]
           ]
  end

  test "migration rewrites the legacy Console resource catalog", ctx do
    patterns = [
      "agent_library",
      "agent_workers",
      "agents",
      "ai_gateway_conversations",
      "ai_gateway_provider:*",
      "ai_gateway_provider_kinds",
      "ai_gateway_providers",
      "app_configuration:*",
      "app_configurations",
      "automation_jobs",
      "background_agent_jobs",
      "brain",
      "console_readiness",
      "control_plane_plugins",
      "conversations",
      "identity_mapping_requests",
      "identity_provider:*",
      "identity_provider_adapters",
      "identity_providers",
      "oidc_client:*",
      "oidc_clients",
      "permission_grant:*",
      "permission_grants",
      "principal:*",
      "principal_group:*",
      "principal_groups",
      "principals",
      "schedules",
      "signal_bindings",
      "signals_adapters",
      "webhooks",
      "worker_env:*",
      "worker_envs",
      "worker_provider:*",
      "worker_providers",
      "agent:*",
      "agent:*:automation_jobs",
      "agent:*:files",
      "agent:*:library",
      "agent:*:model_profile:*",
      "agent:*:model_profiles",
      "agent:*:schedules",
      "agent:*:sessions",
      "agent:*:signal_bindings",
      "agent:*:token_quota",
      "agent:*:worker_env:*",
      "agent:*:worker_envs",
      "agent:*:workflow"
    ]

    for pattern <- patterns, do: grant(ctx, pattern, "read")
    run_migration()

    assert Repo.query!("SELECT resource_pattern FROM permission_grants ORDER BY resource_pattern").rows ==
             patterns |> Enum.map(&["site_console:" <> &1]) |> Enum.sort()
  end

  test "migration accepts resource text and locally bound resource identifiers", ctx do
    grant(ctx, "principal:*", "read", ~s|["resource"].exists(resource, resource == "resource")|)
    run_migration()

    assert Repo.query!("SELECT resource_pattern FROM permission_grants").rows == [
             ["site_console:principal:*"]
           ]
  end

  test "Principal and anchor CHECK constraints reject all nullable discriminants", ctx do
    run_migration()

    for sql <- [
          "UPDATE principals SET membership=NULL WHERE type='human'",
          "UPDATE principals SET membership='member' WHERE type='agent'",
          "UPDATE principals SET membership='guest' WHERE type='system'",
          "UPDATE principals SET membership='outsider' WHERE type='human'"
        ],
        do: rejects(sql, "principals_membership_shape")

    for sql <- [
          "UPDATE pages SET parent_anchor_id=NULL WHERE id='#{ctx.trash}'",
          "UPDATE pages SET parent_anchor_id=id WHERE id='#{ctx.trash}'",
          "UPDATE pages SET parent_anchor_id='#{ctx.root}' WHERE id='#{ctx.leaf}'",
          "UPDATE pages SET acl_anchor_id=id WHERE id='#{ctx.child}'",
          "UPDATE pages SET parent_anchor_id=id WHERE id='#{ctx.root}'"
        ],
        do: rejects(sql, "pages_acl_anchor_shape")

    rejects(
      "UPDATE pages SET acl_anchor_id=NULL WHERE id='#{ctx.leaf}'",
      "pages",
      :not_null_violation
    )
  end

  test "Grant CHECK constraints reject nullable owners, source actions, scopes, and mismatched targets",
       ctx do
    run_migration()
    id = grant(ctx, "pod:space:**", "page_view")

    for mutation <- [
          "principal_uid=NULL",
          "group_id='#{ctx.group}'",
          "source_action='page_view'",
          "principal_uid=NULL, source_page_id='#{ctx.root}', target_page_id='#{ctx.child}', target_scope='self', resource_pattern='pod:**:#{ctx.child}:page'",
          "principal_uid=NULL, source_page_id='#{ctx.root}', source_action='page_view'"
        ],
        do:
          rejects(
            "UPDATE permission_grants SET #{mutation} WHERE id='#{id}'",
            "permission_grants_owner_shape"
          )

    for mutation <- [
          "target_page_id='#{ctx.child}'",
          "target_scope='self'",
          "resource_pattern='**'",
          "action='update'",
          "target_page_id='#{ctx.child}',target_scope='bad'",
          "target_page_id='#{ctx.child}',target_scope='self',resource_pattern='pod:**:#{ctx.root}:page'",
          "principal_uid=NULL, source_page_id='#{ctx.root}', source_action='page_view', target_page_id='#{ctx.root}', target_scope='self', resource_pattern='pod:**:#{ctx.root}:page'"
        ],
        do:
          rejects(
            "UPDATE permission_grants SET #{mutation} WHERE id='#{id}'",
            "permission_grants_pod_action_shape"
          )

    Repo.query!(
      "UPDATE permission_grants SET principal_uid=NULL,source_page_id=$1::text::uuid,source_action='page_view',target_page_id=$2::text::uuid,target_scope='self',resource_pattern=$3 WHERE id=$4::text::uuid",
      [ctx.root, ctx.child, "pod:**:#{ctx.child}:page", id]
    )

    assert Repo.query!("SELECT source_action,target_scope FROM permission_grants").rows == [
             ["page_view", "self"]
           ]

    other_tenant = Ecto.UUID.generate()

    rejects(
      "UPDATE permission_grants SET tenant_id='#{other_tenant}' WHERE id='#{id}'",
      "permission_grants_source_page_fkey",
      :foreign_key_violation
    )
  end

  defp anchors do
    Repo.query!(
      "SELECT id::text,is_acl_anchor,acl_anchor_id::text,parent_anchor_id::text,has_local_acl FROM pages"
    ).rows
    |> Map.new(fn [id | values] -> {id, values} end)
  end

  defp grant(ctx, pattern, action, condition \\ "true", owner \\ :principal) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO permission_grants (id,tenant_id,principal_uid,group_id,resource_pattern,action,condition) VALUES ($1::text::uuid,$2::text::uuid,$3,$4::text::uuid,$5,$6,$7)",
      [
        id,
        ctx.tenant_id,
        if(owner == :principal, do: "human"),
        if(owner == :group, do: ctx.group),
        pattern,
        action,
        condition
      ]
    )

    id
  end

  defp rejects(sql, constraint, code \\ :check_violation) do
    result = Repo.query(sql, [], mode: :savepoint)
    assert {:error, %Postgrex.Error{postgres: error}} = result
    assert error.code == code
    assert (error[:constraint] || error[:table]) == constraint
  end

  defp run_migration do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_023_100_600,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end
end
