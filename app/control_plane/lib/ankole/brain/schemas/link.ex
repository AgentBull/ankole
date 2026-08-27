defmodule Ankole.Brain.Schemas.Link do
  @moduledoc """
  One directed relation edge between two objects. Links widen relation-based
  recall candidates; they never bypass the audience scope of the endpoint
  object, claim, or timeline content.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_links" do
    field :from_object_slug, :string
    field :to_object_slug, :string
    field :link_type, :string, default: ""
    field :context, :string, default: ""
    field :link_source, :string
    field :link_kind, :string
    field :origin_object_slug, :string
    field :origin_field, :string
    field :resolution_type, :string
    field :created_at, :utc_datetime_usec
  end
end
