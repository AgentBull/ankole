defmodule Ankole.Brain.Schemas.SchemaSuggestion do
  @moduledoc """
  One vocabulary promotion suggestion awaiting Console review.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_schema_suggestions" do
    field :kind, :string
    field :term, :string
    field :target_type, :string
    field :evidence_count, :integer
    field :rationale, :string
    field :status, :string, default: "pending"
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end
end
