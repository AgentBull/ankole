defmodule Ankole.Ecto.ScopeReceivedFilesToChatsMigrationTest do
  use Ankole.DataCase, async: false

  @migration Ankole.Repo.Migrations.ScopeReceivedFilesToChats

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261011072443_scope_received_files_to_chats.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "chat_drive_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")

    Repo.query!("""
    CREATE TABLE agent_files (
      tenant_id uuid NOT NULL,
      agent_uid text NOT NULL,
      path text NOT NULL,
      signal_channel_id text,
      source text NOT NULL,
      sha256 bytea NOT NULL,
      updated_at timestamp NOT NULL DEFAULT '2026-10-01 00:00:00',
      PRIMARY KEY (tenant_id, agent_uid, path)
    )
    """)

    %{tenant_id: Ecto.UUID.dump!(Ecto.UUID.generate())}
  end

  test "moves known inbound paths without changing content or timestamps and keeps unknown provenance",
       %{tenant_id: tenant_id} do
    digest = :crypto.hash(:sha256, "report")
    insert_file(tenant_id, "inbox/abc/report.txt", "mock:dm:alice/bob", "inbound", digest)
    insert_file(tenant_id, "inbox/unknown.txt", nil, "inbound", digest)
    insert_file(tenant_id, "inbox/generated.txt", "mock:dm:alice", "generated", digest)
    other_tenant = Ecto.UUID.dump!(Ecto.UUID.generate())
    insert_file(other_tenant, "inbox/abc/report.txt", "mock:dm:charlie", "inbound", digest)

    assert ExUnit.CaptureLog.capture_log(&migrate/0) =~
             "1 received drive files have no source channel"

    rows =
      Repo.query!("SELECT tenant_id, path, sha256, updated_at FROM agent_files ORDER BY path").rows

    assert [
             [
               ^tenant_id,
               "chats/mock:dm:alice%2Fbob/inbox/abc/report.txt",
               ^digest,
               ~N[2026-10-01 00:00:00.000000]
             ],
             [
               ^other_tenant,
               "chats/mock:dm:charlie/inbox/abc/report.txt",
               ^digest,
               ~N[2026-10-01 00:00:00.000000]
             ],
             [^tenant_id, "inbox/generated.txt", ^digest, ~N[2026-10-01 00:00:00.000000]],
             [^tenant_id, "inbox/unknown.txt", ^digest, ~N[2026-10-01 00:00:00.000000]]
           ] = rows

    migrate()

    assert Repo.query!(
             "SELECT tenant_id, path, sha256, updated_at FROM agent_files ORDER BY path"
           ).rows == rows
  end

  test "refuses a file or folder collision without replacing operator files", %{
    tenant_id: tenant_id
  } do
    digest = :crypto.hash(:sha256, "report")
    insert_file(tenant_id, "inbox/abc/report.txt", "mock:dm:alice", "inbound", digest)
    insert_file(tenant_id, "chats/mock:dm:alice", nil, "agent", digest)

    assert_raise Ecto.MigrationError,
                 ~r/conflicts with an existing conversation drive path/,
                 &migrate/0

    assert Repo.query!("SELECT path FROM agent_files ORDER BY path").rows == [
             ["chats/mock:dm:alice"],
             ["inbox/abc/report.txt"]
           ]
  end

  test "refuses paths that exceed the drive limits", %{tenant_id: tenant_id} do
    insert_file(
      tenant_id,
      "inbox/report.txt",
      String.duplicate("x", 256),
      "inbound",
      :crypto.hash(:sha256, "report")
    )

    assert_raise Ecto.MigrationError, ~r/does not fit its conversation drive path/, &migrate/0
    assert Repo.query!("SELECT path FROM agent_files").rows == [["inbox/report.txt"]]
  end

  defp migrate do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_011_072_443,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp insert_file(tenant_id, path, channel_id, source, digest) do
    Repo.query!(
      """
      INSERT INTO agent_files (tenant_id, agent_uid, path, signal_channel_id, source, sha256)
      VALUES ($1, 'agent', $2, $3, $4, $5)
      """,
      [tenant_id, path, channel_id, source, digest]
    )
  end
end
