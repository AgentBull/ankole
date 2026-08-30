defmodule Ankole.Brain.Schemas.Chunk do
  @moduledoc """
  One retrieval unit of an object's current content. Chunks are a rebuildable
  projection: body chunks come first, then compiled timeline chunks continue
  the same index sequence. Each row carries exactly one audience scope.
  """

  use Ecto.Schema

  alias Ankole.Brain.Schemas.Object

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_chunks" do
    belongs_to :object, Object, type: Ankole.Ecto.UUIDv7
    field :chunk_index, :integer
    field :content_kind, :string, default: "body"
    field :audience_scope, :string
    field :chunk_text, :string
    field :token_count, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_signature, :string
    field :embedding_error, :string
    field :embedded_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end
end
