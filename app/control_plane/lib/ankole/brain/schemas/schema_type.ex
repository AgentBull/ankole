defmodule Ankole.Brain.Schemas.SchemaType do
  @moduledoc """
  One registered type of the instance ontology. `brain_objects.type` writes
  validate against these rows, not against pack seed files.
  """

  use Ecto.Schema

  alias Ankole.Brain.Ecto.StringList

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_schema_types" do
    field :name, :string
    field :primitive, :string
    field :slug_prefix, :string
    field :subtypes, StringList, default: []
    field :extractable, :boolean, default: false
    field :expert_routing, :boolean, default: false
    field :pack_name, :string
    field :created_at, :utc_datetime_usec
  end
end
