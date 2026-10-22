defmodule Ankole.Brain.Schemas.SchemaPack do
  @moduledoc "An installed schema pack and its immutable manifest."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_schema_packs")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(name: "brain_schema_packs_name_key")

    check_constraints do
      check_constraint(:manifest, "brain_schema_packs_manifest_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:version, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:content_hash, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:manifest, Ankole.Ash.Types.JSONMap, allow_nil?: false)
    attribute(:installed_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:name, [:name])
  end

  actions do
    defaults([:read])

    create :install do
      accept([:id, :name, :version, :content_hash, :manifest, :installed_at])
    end

    create_if_absent :ensure_promoted do
      accept([])
      change(set_attribute(:name, "promoted"))
      change(set_attribute(:version, "0"))
      change(set_attribute(:content_hash, "promoted"))
      change(set_attribute(:manifest, %{"name" => "promoted", "promoted" => true}))
      upsert_identity(:name)
    end

    # The operation owns its transaction; Ankole.Brain.SchemaPacks gives the steps.
    action :install_packs, :map do
      argument(:names, {:array, :string}, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Errors.wrap(Ankole.Brain.SchemaPacks.install_packs_in_tx(Ankole.Repo, args.names))
      end)
    end
  end

  @type t :: %__MODULE__{}
end
