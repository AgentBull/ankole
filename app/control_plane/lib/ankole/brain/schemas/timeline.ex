defmodule Ankole.Brain.Schemas.Timeline do
  @moduledoc """
  One structured timeline event of an object. Each row owns its audience
  scope; retrieval compiles visible rows into timeline chunks of the host
  object instead of storing a second vector.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_timelines" do
    field :object_slug, :string
    field :author_uid, :string
    field :date, :date
    field :provenance, :string
    field :summary, :string
    field :detail, :string, default: ""
    field :event_object_slug, :string
    field :audience_scope, :string
    field :created_at, :utc_datetime_usec
  end
end
