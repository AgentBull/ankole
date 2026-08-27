defmodule Ankole.Repo.Migrations.InstallGeneralSchemaPack do
  @moduledoc false

  use Ecto.Migration

  alias Ankole.Ecto.UUIDv7

  # Instances that completed setup before BrainV3 never saw the setup-time
  # industry selection, so this data migration installs the general base pack.
  # Fresh instances skip it: their setup completion materializes the selected
  # packs, and this migration finds setup incomplete.
  #
  # Every installed value below is the frozen fact of general pack 1.0.0 as it
  # shipped with this migration. The migration must not call the current
  # SchemaPacks module or read the current seed file: those move with the
  # product, and a replay must install what shipped, not what the tree holds
  # on the day it runs.

  @content_hash "1bd13028f1554fe4986a36bbe1635f98"

  @manifest_json ~S({"api_version":"ankole-brain-schema-pack-v1","calibration_domains":[],"description":"Minimal instance ontology for any digital employee.","extends":null,"link_types":[{"inverse":"relates_to","name":"relates_to"},{"name":"mentions"},{"inverse":"has_part","name":"part_of"},{"inverse":"employs","name":"works_at"},{"inverse":"founded_by","name":"founded"},{"inverse":"attended_by","name":"attended"},{"inverse":"authored_by","name":"authored"},{"inverse":"vendor_of","name":"customer_of"},{"inverse":"competes_with","name":"competes_with"},{"name":"derived_from"},{"name":"sourced_from"},{"name":"supersedes"}],"name":"general","page_types":[{"expert_routing":true,"extractable":false,"name":"person","primitive":"entity","slug_prefix":"people/","subtypes":["internal","external"]},{"expert_routing":true,"extractable":false,"name":"agent","primitive":"entity","slug_prefix":"agents/","subtypes":["internal","external"]},{"expert_routing":true,"extractable":false,"name":"company","primitive":"entity","slug_prefix":"companies/","subtypes":["company","department","government","nonprofit"]},{"expert_routing":false,"extractable":false,"name":"event","primitive":"temporal","slug_prefix":"events/","subtypes":["meeting","milestone","incident","external"]},{"expert_routing":false,"extractable":true,"name":"media","primitive":"media","slug_prefix":"media/","subtypes":["article","video","book","podcast","paper","post"]},{"expert_routing":false,"extractable":true,"name":"document","primitive":"media","slug_prefix":"documents/","subtypes":["contract","report","policy"]},{"expert_routing":false,"extractable":true,"name":"analysis","primitive":"media","slug_prefix":"analysis/"},{"expert_routing":false,"extractable":false,"name":"project","primitive":"concept","slug_prefix":"projects/"},{"expert_routing":false,"extractable":true,"name":"concept","primitive":"concept","slug_prefix":"concepts/"},{"expert_routing":false,"extractable":true,"name":"note","primitive":"concept","slug_prefix":"notes/"}],"version":"1.0.0"})

  # {name, primitive, slug_prefix, subtypes as JSON, extractable, expert_routing}
  @types [
    {"person", "entity", "people/", ~S(["internal","external"]), false, true},
    {"agent", "entity", "agents/", ~S(["internal","external"]), false, true},
    {"company", "entity", "companies/", ~S(["company","department","government","nonprofit"]),
     false, true},
    {"event", "temporal", "events/", ~S(["meeting","milestone","incident","external"]), false,
     false},
    {"media", "media", "media/", ~S(["article","video","book","podcast","paper","post"]), true,
     false},
    {"document", "media", "documents/", ~S(["contract","report","policy"]), true, false},
    {"analysis", "media", "analysis/", ~S([]), true, false},
    {"project", "concept", "projects/", ~S([]), false, false},
    {"concept", "concept", "concepts/", ~S([]), true, false},
    {"note", "concept", "notes/", ~S([]), true, false}
  ]

  # {name, inverse}
  @link_types [
    {"relates_to", "relates_to"},
    {"mentions", nil},
    {"part_of", "has_part"},
    {"works_at", "employs"},
    {"founded", "founded_by"},
    {"attended", "attended_by"},
    {"authored", "authored_by"},
    {"customer_of", "vendor_of"},
    {"competes_with", "competes_with"},
    {"derived_from", nil},
    {"sourced_from", nil},
    {"supersedes", nil}
  ]

  def up do
    if setup_completed?() and not general_installed?() do
      execute("""
      INSERT INTO brain_schema_packs (id, name, version, content_hash, manifest)
      VALUES ('#{UUIDv7.autogenerate()}', 'general', '1.0.0', '#{@content_hash}',
              $manifest$#{@manifest_json}$manifest$::jsonb)
      """)

      type_rows =
        Enum.map_join(@types, ",\n", fn {name, primitive, prefix, subtypes, extractable, routing} ->
          "('#{UUIDv7.autogenerate()}', '#{name}', '#{primitive}', '#{prefix}', " <>
            "'#{subtypes}'::jsonb, #{extractable}, #{routing}, 'general')"
        end)

      execute("""
      INSERT INTO brain_schema_types
        (id, name, primitive, slug_prefix, subtypes, extractable, expert_routing, pack_name)
      VALUES
      #{type_rows}
      """)

      link_rows =
        Enum.map_join(@link_types, ",\n", fn {name, inverse} ->
          "('#{UUIDv7.autogenerate()}', '#{name}', #{text_or_null(inverse)}, 'general')"
        end)

      execute("""
      INSERT INTO brain_schema_link_types (id, name, inverse, pack_name)
      VALUES
      #{link_rows}
      """)
    end
  end

  def down do
    # Installed schema state stays; removing it would orphan typed objects.
  end

  defp text_or_null(nil), do: "NULL"
  defp text_or_null(text), do: "'#{text}'"

  defp setup_completed? do
    %{rows: rows} =
      repo().query!(
        """
        SELECT value->'value' FROM app_configurations
        WHERE scope = 'global' AND key = 'setup.completed'
        """,
        []
      )

    match?([[true]], rows)
  end

  defp general_installed? do
    %{rows: rows} =
      repo().query!("SELECT 1 FROM brain_schema_packs WHERE name = 'general' LIMIT 1", [])

    rows != []
  end
end
