defmodule Ankole.Brain.Schemas.TakeDomainAssignment do
  @moduledoc "The first accepted analysis-domain assignment for a Take."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_take_domain_assignments")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:take_claim_id, "brain_take_domain_assignments_take_claim_id_fkey"}])
    identity_index_names(take_domain: "brain_take_domain_assignments_key")

    check_constraints do
      check_constraint(:confidence, "brain_take_domain_assignments_confidence_range")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:take_claim_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:domain, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:pack, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:assignment_provenance, :string, allow_nil?: true, constraints: [trim?: false])

    attribute(:confidence, :float,
      allow_nil?: false,
      default: 1.0,
      constraints: [min: 0.0, max: 1.0]
    )

    attribute(:assigned_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:take_domain, [:take_claim_id, :domain])
  end

  actions do
    defaults([:read])

    create_if_absent :assign_once do
      accept([
        :id,
        :take_claim_id,
        :domain,
        :pack,
        :assignment_provenance,
        :confidence,
        :assigned_at
      ])

      upsert_identity(:take_domain)
    end
  end

  @type t :: %__MODULE__{}
end
