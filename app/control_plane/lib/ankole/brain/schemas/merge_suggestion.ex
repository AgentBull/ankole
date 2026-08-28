defmodule Ankole.Brain.Schemas.MergeSuggestion do
  @moduledoc """
  One duplicate-page merge suggestion awaiting Console review.

  The slugs are plain text on purpose: approval deletes the merged page,
  and the decided row stays as the audit record. Readers resolve the slugs
  through the redirect ladder.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_merge_suggestions" do
    field :a_slug, :string
    field :b_slug, :string
    field :reason, :string
    field :status, :string, default: "pending"
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end
end
