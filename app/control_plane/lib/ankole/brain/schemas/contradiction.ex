defmodule Ankole.Brain.Schemas.Contradiction do
  @moduledoc """
  One contradiction probe finding between two claims. The probe writes here
  only; claims stay unchanged until a human resolves the pair.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_contradictions" do
    field :a_claim_id, Ankole.Ecto.UUIDv7
    field :b_claim_id, Ankole.Ecto.UUIDv7
    field :verdict, :string
    field :axis, :string, default: ""
    field :severity, :string
    field :confidence, :float
    field :status, :string, default: "open"
    field :resolution_note, :string
    field :created_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
  end
end
