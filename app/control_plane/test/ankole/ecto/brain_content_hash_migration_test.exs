defmodule Ankole.Ecto.BrainContentHashMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Object

  @migration Ankole.Repo.Migrations.CoverBrainEditFieldsInContentHash
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261016000300_cover_brain_edit_fields_in_content_hash.exs",
        __DIR__
      )
    )
  end

  test "stored tokens match fresh writes across tenants without changing content or timestamps",
       %{
         tenant: first
       } do
    second = create_tenant()

    objects =
      for {tenant, date, subtype} <- [{first, ~D[2026-08-01], "reference"}, {second, nil, nil}] do
        Repo.with_tenant(tenant.id, fn ->
          {:ok, _} = SchemaPacks.install_packs([])

          {:ok, object} =
            Objects.create_object(
              %{
                slug: "notes/migration",
                type: "note",
                title: "Migration 文本",
                body: "Body with\na second line",
                meta: %{"z" => String.duplicate("x", 5_000), "a" => %{"nested" => ["one", 2]}},
                subtype: subtype,
                effective_date: date
              },
              :system
            )

          object
        end)
      end

    # Use a transaction-local schema like the existing migration tests. The
    # production migration runs on the real table; this copy isolates its data.
    schema = "brain_hash_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("CREATE TABLE #{schema}.brain_objects (LIKE public.brain_objects INCLUDING ALL)")

    for object <- objects do
      Repo.query!(
        "INSERT INTO #{schema}.brain_objects SELECT * FROM public.brain_objects WHERE id = $1",
        [Ecto.UUID.dump!(object.id)]
      )
    end

    # Cross the migration's batch boundary with unchanged content. Identity
    # and slug are outside the edit token, so every copy must keep its token.
    first_object = hd(objects)

    assert %{num_rows: 1_001} =
             Repo.query!(
               """
               INSERT INTO #{schema}.brain_objects
               SELECT (jsonb_populate_record(NULL::#{schema}.brain_objects,
                 to_jsonb(object) || jsonb_build_object(
                   'id', gen_random_uuid(), 'slug', 'notes/migration-batch-' || number))).*
               FROM public.brain_objects AS object, generate_series(1, 1001) AS number
               WHERE object.id = $1
               """,
               [Ecto.UUID.dump!(first_object.id)]
             )

    Repo.query!("SET LOCAL search_path TO #{schema}")
    Repo.query!("UPDATE brain_objects SET content_hash = 'old-token'")
    run_migration()

    assert %{rows: [[1_001]]} =
             Repo.query!(
               "SELECT count(*) FROM brain_objects WHERE slug LIKE 'notes/migration-batch-%' AND content_hash = $1",
               [first_object.content_hash]
             )

    for object <- objects do
      migrated = Repo.with_tenant(object.tenant_id, fn -> Repo.get!(Object, object.id) end)
      assert_persisted_equal(migrated, object)
    end

    run_migration()

    for object <- objects do
      assert_persisted_equal(
        Repo.with_tenant(object.tenant_id, fn -> Repo.get!(Object, object.id) end),
        object
      )
    end
  end

  defp run_migration do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_016_000_300,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end
end
