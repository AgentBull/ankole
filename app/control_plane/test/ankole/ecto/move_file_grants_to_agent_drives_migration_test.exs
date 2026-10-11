defmodule Ankole.Ecto.MoveFileGrantsToAgentDrivesMigrationTest do
  use Ankole.DataCase, async: false

  @migration Ankole.Repo.Migrations.MoveFileGrantsToAgentDrives

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261002120100_move_file_grants_to_agent_drives.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "file_grants_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")

    Repo.query!("""
    CREATE TABLE permission_grants (
      id uuid PRIMARY KEY,
      principal_uid text,
      group_id uuid,
      resource_pattern text NOT NULL,
      action text NOT NULL,
      condition text NOT NULL DEFAULT 'true',
      description text,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp NOT NULL DEFAULT now(),
      updated_at timestamp NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX permission_grants_principal_natural_index
    ON permission_grants (principal_uid, resource_pattern, action, condition)
    WHERE principal_uid IS NOT NULL
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX permission_grants_group_natural_index
    ON permission_grants (group_id, resource_pattern, action, condition)
    WHERE group_id IS NOT NULL
    """)

    :ok
  end

  test "moves applicable grants with UUIDv7 IDs and preserves an existing Agent grant" do
    group_id = Ankole.Ecto.UUIDv7.autogenerate()
    existing_id = Ankole.Ecto.UUIDv7.autogenerate()

    grants = [
      {"alice", nil, "agent_computer_worker:*:files", "read", "true", "pooled read"},
      {"alice", nil, "agent_computer_worker:**", "read", "true", "pooled read"},
      {"alice", nil, "agent_computer_worker:*:files", "update", "owner", "conditional update"},
      {nil, group_id, "agent_computer_worker:**", "delete", "true", "group delete"},
      {"bob", nil, "agent_computer_worker:*:files", "read", "true", "superseded"},
      {"alice", nil, "agent_computer_worker:one:files", "read", "true", "one Worker"},
      {"alice", nil, "agent_computer_worker:*:*", "read", "true", "old resource"},
      {"alice", nil, "agent_computer_worker:**", "execute", "true", "old action"}
    ]

    for {principal_uid, owner_group, resource, action, condition, description} <- grants do
      insert_grant(
        Ankole.Ecto.UUIDv7.autogenerate(),
        principal_uid,
        owner_group,
        resource,
        action,
        condition,
        description
      )
    end

    insert_grant(existing_id, "bob", nil, "agent:*:files", "read", "true", "keep")

    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_002_120_100,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )

    rows =
      Repo.query!("""
      SELECT id::text, principal_uid, group_id::text, resource_pattern, action, condition, description
      FROM permission_grants
      ORDER BY principal_uid NULLS LAST, action
      """).rows

    assert [
             [read_id, "alice", nil, "agent:*:files", "read", "true", "pooled read"],
             [update_id, "alice", nil, "agent:*:files", "update", "owner", "conditional update"],
             [^existing_id, "bob", nil, "agent:*:files", "read", "true", "keep"],
             [delete_id, nil, ^group_id, "agent:*:files", "delete", "true", "group delete"]
           ] = rows

    for id <- [read_id, update_id, delete_id] do
      assert String.at(id, 14) == "7"
      refute id == existing_id
    end
  end

  defp insert_grant(id, principal_uid, group_id, resource, action, condition, description) do
    Repo.query!(
      """
      INSERT INTO permission_grants
        (id, principal_uid, group_id, resource_pattern, action, condition, description)
      VALUES ($1::uuid, $2, $3::uuid, $4, $5, $6, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        principal_uid,
        if(group_id, do: Ecto.UUID.dump!(group_id)),
        resource,
        action,
        condition,
        description
      ]
    )
  end
end
