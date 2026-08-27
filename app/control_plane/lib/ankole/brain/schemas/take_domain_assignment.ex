defmodule Ankole.Brain.Schemas.TakeDomainAssignment do
  @moduledoc """
  One analysis-domain assignment of a Take claim.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_take_domain_assignments" do
    field :take_claim_id, Ankole.Ecto.UUIDv7
    field :domain, :string
    field :pack, :string
    field :assignment_provenance, :string
    field :confidence, :float, default: 1.0
    field :assigned_at, :utc_datetime_usec
  end
end
