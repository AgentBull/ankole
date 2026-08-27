defmodule Ankole.Brain.Schemas.Claim do
  @moduledoc """
  One atomic assertion: a bitemporal Fact or a calibratable Take. The two
  GBrain tables share this physical table; `claim_type` keeps both full
  semantics apart, and the database `brain_claims_type_shape` check keeps the
  field families disjoint.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "brain_claims" do
    field :author_uid, :string
    field :claim_type, :string
    field :object_slug, :string
    field :signal_gateway_channel_id, :string
    field :claim, :string
    field :kind, :string
    field :holder, :string
    field :audience_scope, :string

    # Fact fields; NULL for takes.
    field :notability, :string
    field :context, :string
    field :valid_from, :utc_datetime_usec
    field :valid_until, :utc_datetime_usec
    field :expired_at, :utc_datetime_usec
    field :consolidated_at, :utc_datetime_usec
    field :consolidated_into, Ankole.Ecto.UUIDv7
    field :confidence, :float
    field :provenance_session, :string

    # Take fields; NULL for facts.
    field :weight, :float
    field :since_date, :string
    field :until_date, :string
    field :active, :boolean
    field :graded_quality, :string
    field :graded_confidence, :float
    field :graded_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :resolved_outcome, :boolean
    field :resolved_quality, :string
    field :resolved_value, :float
    field :resolved_unit, :string
    field :resolution_provenance, :string
    field :resolved_by, :string

    # Shared fields.
    field :superseded_by, Ankole.Ecto.UUIDv7
    field :provenance, :string
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_signature, :string
    field :embedding_error, :string
    field :embedded_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: :updated_at)
  end
end
