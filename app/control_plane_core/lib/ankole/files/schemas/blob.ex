defmodule Ankole.Files.Schemas.Blob do
  @moduledoc """
  One distinct byte content in the file service.

  The object key is derived from the SHA-256 digest (`Ankole.Files.object_key/1`),
  so it is not stored. `deleting` marks a row that the collection job has started
  to remove; no new reference may point to it.
  """

  use Ankole.Schema, tenancy: :site

  @primary_key {:sha256, :binary, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "files" do
    field :size, :integer
    field :deleting, :boolean, default: false
    field :created_at, :utc_datetime_usec, read_after_writes: true
    field :last_referenced_at, :utc_datetime_usec, read_after_writes: true
  end
end
