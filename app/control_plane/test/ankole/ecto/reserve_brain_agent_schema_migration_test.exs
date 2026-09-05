defmodule Ankole.Ecto.ReserveBrainAgentSchemaMigrationTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.{SchemaPack, SchemaType}

  @migration Ankole.Repo.Migrations.ReserveBrainAgentSchema
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260904203736_reserve_brain_agent_schema.exs",
        __DIR__
      )
    )
  end

  test "upgrades the stored declaration and preserves add-on installation" do
    {:ok, _result} = SchemaPacks.install_packs([])
    pack = Repo.get_by!(SchemaPack, name: "general")
    {:ok, seed} = SchemaPacks.load_seed("general")

    legacy =
      pack.manifest
      |> Map.put("version", "1.1.0")
      |> Map.update!("page_types", fn types ->
        Enum.map(types, fn
          %{"name" => "agent"} = type -> Map.put(type, "subtypes", ["internal", "external"])
          type -> type
        end)
      end)

    Repo.update!(
      Ecto.Changeset.change(pack, version: "1.1.0", manifest: legacy, content_hash: "legacy")
    )

    type = Repo.get_by!(SchemaType, name: "agent")
    Repo.update!(Ecto.Changeset.change(type, subtypes: ["internal", "external"]))

    Enum.each(@migration.up_sqls(), &Repo.query!/1)
    updated = Repo.get!(SchemaPack, pack.id)
    assert updated.version == "1.1.1"
    assert updated.manifest == seed.manifest
    assert updated.content_hash == seed.content_hash
    assert Repo.get!(SchemaType, type.id).subtypes == ["internal"]
    assert "external" in Repo.get_by!(SchemaType, name: "person").subtypes
    assert {:ok, _result} = SchemaPacks.install_packs(["software"])

    Enum.each(@migration.up_sqls(), &Repo.query!/1)
    assert Repo.get!(SchemaPack, pack.id) == updated
  end
end
