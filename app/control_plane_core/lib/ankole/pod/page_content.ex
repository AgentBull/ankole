defmodule Ankole.Pod.PageContent do
  @moduledoc """
  The document of one page: its canonical page-tree XML and the plain text that
  the kernel derives from it for search.

  The content matches the revision on its page row.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset

  alias Ankole.Ecto.ActorRef

  @primary_key {:page_id, Ankole.Ecto.UUIDv7, []}

  schema "page_contents" do
    field :content, :string
    field :plain_text, :string, default: ""
    field :updated_by, ActorRef
    field :updated_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(content, attrs) do
    content
    |> cast(attrs, [:page_id, :content, :plain_text, :updated_by, :updated_at], empty_values: [])
    |> validate_required([:page_id, :content, :plain_text, :updated_by, :updated_at])
    |> foreign_key_constraint(:page_id, name: :page_contents_tenant_id_page_id_fkey)
    |> unique_constraint(:page_id, name: :page_contents_pkey)
  end
end
