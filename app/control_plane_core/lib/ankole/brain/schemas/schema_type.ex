defmodule Ankole.Brain.Schemas.SchemaType do
  @moduledoc "A registered object type with additive subtype vocabulary."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_schema_types")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:pack_name, "brain_schema_types_pack_name_fkey"}])

    identity_index_names(
      name: "brain_schema_types_name_key",
      prefix: "brain_schema_types_prefix_key"
    )

    check_constraints do
      check_constraint(:primitive, "brain_schema_types_primitive_allowed")
      check_constraint(:subtypes, "brain_schema_types_subtypes_strings")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:primitive, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:slug_prefix, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:subtypes, Ankole.Ash.Types.StringList, allow_nil?: false, default: [])
    attribute(:extractable, :boolean, allow_nil?: false, default: false)
    attribute(:expert_routing, :boolean, allow_nil?: false, default: false)
    attribute(:pack_name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:name, [:name])
    identity(:prefix, [:slug_prefix])
  end

  actions do
    defaults([:read])

    create :register do
      accept([
        :id,
        :name,
        :primitive,
        :slug_prefix,
        :subtypes,
        :extractable,
        :expert_routing,
        :pack_name,
        :created_at
      ])
    end

    update :add_subtypes do
      require_atomic?(true)
      accept([])
      argument(:subtypes, Ankole.Ash.Types.StringList, allow_nil?: false)

      change(
        atomic_update(
          :subtypes,
          expr(
            fragment(
              "(SELECT COALESCE(jsonb_agg(value ORDER BY first_position),'[]'::jsonb) FROM (SELECT value,min(position) AS first_position FROM jsonb_array_elements(? || to_jsonb(?::text[])) WITH ORDINALITY AS items(value,position) GROUP BY value) unique_items)",
              subtypes,
              ^arg(:subtypes)
            )
          )
        )
      )
    end
  end

  @type t :: %__MODULE__{}
end
