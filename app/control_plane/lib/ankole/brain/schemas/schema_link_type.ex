defmodule Ankole.Brain.Schemas.SchemaLinkType do
  @moduledoc """
  One relation predicate of the instance ontology.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_schema_link_types" do
    field :name, :string
    field :inverse, :string
    field :pack_name, :string
    field :created_at, :utc_datetime_usec
  end
end
