defmodule Ankole.Brain.Schemas.ObjectVersion do
  @moduledoc """
  One body snapshot taken immediately before an object update. New objects,
  soft deletes, and status write-backs create no version.
  """

  use Ecto.Schema

  alias Ankole.Brain.Schemas.Object

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_object_versions" do
    belongs_to :object, Object, type: Ankole.Ecto.UUIDv7
    field :author_uid, :string
    field :body, :string
    field :meta, :map, default: %{}
    field :snapshot_at, :utc_datetime_usec
  end
end
