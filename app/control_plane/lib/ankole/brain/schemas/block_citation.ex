defmodule Ankole.Brain.Schemas.BlockCitation do
  @moduledoc "A rebuildable index of strict src markers in one knowledge block."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Brain.Schemas.EntryBlock

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @type t :: %__MODULE__{}

  schema "brain_block_citations" do
    belongs_to :block, EntryBlock, primary_key: true
    field :document_id, :string, primary_key: true

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(citation, attrs) do
    citation
    |> cast(attrs, [:block_id, :document_id])
    |> validate_required([:block_id, :document_id])
    |> foreign_key_constraint(:block_id)
    |> unique_constraint([:block_id, :document_id],
      name: :brain_block_citations_pkey
    )
    |> check_constraint(:document_id, name: :brain_block_citations_document_id_check)
  end
end
