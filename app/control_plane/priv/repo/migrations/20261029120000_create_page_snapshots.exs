defmodule Ankole.Repo.Migrations.CreatePageSnapshots do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE page_snapshots (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id uuid NOT NULL,
      revision bigint NOT NULL CONSTRAINT page_snapshots_revision_check CHECK (revision >= 0),
      title text NOT NULL,
      icon text,
      content text NOT NULL,
      author text NOT NULL,
      document_updated_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL,
      reason text NOT NULL CONSTRAINT page_snapshots_reason_check
        CHECK (reason IN ('created', 'baseline', 'checkpoint', 'before_restore', 'restored')),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE INDEX page_snapshots_page_time_index
    ON page_snapshots (tenant_id, page_id, created_at DESC, id DESC)
    """)

    flush()

    repo().query!(
      "SELECT tenant_id::text, page_id::text FROM page_contents ORDER BY tenant_id, page_id",
      []
    ).rows
    |> Enum.group_by(&hd/1, fn [_tenant_id, page_id] -> page_id end)
    |> Enum.each(fn {tenant_id, page_ids} ->
      page_ids
      |> Enum.chunk_every(200)
      |> Enum.each(&baseline_batch(tenant_id, &1))
    end)
  end

  def down, do: drop(table(:page_snapshots))

  defp baseline_batch(_tenant_id, []), do: :ok

  defp baseline_batch(tenant_id, page_ids) do
    rows =
      repo().query!(
        """
        SELECT page.id::text, page.revision, page.title, page.icon, content.content, content.updated_by, page.updated_at
        FROM page_contents content JOIN pages page
          ON page.tenant_id = content.tenant_id AND page.id = content.page_id
        WHERE content.tenant_id = $1::text::uuid AND content.page_id = ANY($2::text[]::uuid[])
        """,
        [tenant_id, page_ids]
      ).rows

    snapshots =
      Enum.flat_map(rows, fn [page_id, revision, title, icon, xml, author, updated_at] ->
        case Ankole.Kernel.page_comment_info(xml) do
          {:ok, info} ->
            [
              {
                Ankole.Ecto.UUIDv7.autogenerate(),
                tenant_id,
                page_id,
                revision,
                title,
                icon,
                info.stripped_xml,
                author,
                updated_at
              }
            ]

          {:error, _} ->
            []
        end
      end)

    if snapshots != [] do
      {values_sql, reversed_params} =
        snapshots
        |> Enum.with_index()
        |> Enum.map_reduce([], fn {{id, t_id, p_id, rev, title, icon, stripped, author,
                                    updated_at}, idx},
                                  acc ->
          base = idx * 9

          tuple =
            "($#{base + 1}::text::uuid, $#{base + 2}::text::uuid, $#{base + 3}::text::uuid, $#{base + 4}, $#{base + 5}, $#{base + 6}, $#{base + 7}, $#{base + 8}, $#{base + 9}, now(), 'baseline')"

          {tuple, [updated_at, author, stripped, icon, title, rev, p_id, t_id, id | acc]}
        end)

      repo().query!(
        """
        INSERT INTO page_snapshots
          (id, tenant_id, page_id, revision, title, icon, content, author, document_updated_at, created_at, reason)
        VALUES #{Enum.join(values_sql, ", ")}
        """,
        Enum.reverse(reversed_params)
      )
    end
  end
end
