defmodule Ankole.Brain.Schemas.Tag do
  @moduledoc """
  One queryable tag on one object.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_tags" do
    field :object_slug, :string
    field :tag, :string
    field :created_at, :utc_datetime_usec
  end
end
