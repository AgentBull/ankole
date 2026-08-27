defmodule Ankole.Brain.Schemas.SlugAlias do
  @moduledoc """
  One stable redirect from a retired slug to the current canonical slug.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_slug_aliases" do
    field :alias_slug, :string
    field :canonical_slug, :string
    field :notes, :string
    field :created_at, :utc_datetime_usec
  end
end
