defmodule Ankole.Brain.Schemas.ObjectAlias do
  @moduledoc """
  One normalized natural-language alias candidate for one object. Different
  objects can share the same normalized alias; readers order results and
  handle ambiguity explicitly.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_object_aliases" do
    field :alias_norm, :string
    field :object_slug, :string
    field :created_at, :utc_datetime_usec
  end
end
