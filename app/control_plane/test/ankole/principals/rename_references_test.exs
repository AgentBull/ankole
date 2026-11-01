defmodule Ankole.Principals.RenameReferencesTest do
  use Ankole.DataCase, async: false
  alias Ankole.Principals.Rename.References

  test "each typed identity follows a cascading foreign key or its registered rename owner" do
    cascades =
      Repo.query!("""
      SELECT c.conrelid::regclass::text,a.attname
      FROM pg_constraint c
      CROSS JOIN LATERAL unnest(c.conkey) AS k(attnum)
      JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
      WHERE c.contype='f' AND c.confupdtype='c'
      """).rows
      |> MapSet.new(&List.to_tuple/1)

    registry = References.registered_columns()
    covered = MapSet.new(Enum.flat_map(registry, fn {_kind, columns} -> columns end))
    owners = MapSet.new([{"principals", "uid"}, {"agent_workers", "agent_uid"}])

    types = [
      Ankole.Ash.Types.PrincipalKey,
      Ankole.Ash.Types.ActorRef,
      {:array, Ankole.Ash.Types.PrincipalKey},
      {:array, Ankole.Ash.Types.ActorRef}
    ]

    missing =
      for module <- Ankole.TestModules.all(),
          Code.ensure_loaded?(module),
          Spark.Dsl.is?(module, Ash.Resource),
          table = AshPostgres.DataLayer.Info.table(module),
          is_binary(table),
          field <- Ash.Resource.Info.attributes(module),
          field.type in types,
          # Page is a projection of the same Drive row, not a second identity copy.
          key =
            {if(table == "pod_page_nodes", do: "drive_nodes", else: table),
             to_string(field.source || field.name)},
          not MapSet.member?(cascades, key),
          not MapSet.member?(covered, key),
          not MapSet.member?(owners, key),
          do: {module, field.name, key}

    assert missing == []

    columns =
      Repo.query!(
        "SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public'"
      ).rows
      |> MapSet.new(&List.to_tuple/1)

    assert MapSet.subset?(covered, columns),
           "remove registrations for columns that no longer exist"
  end
end
