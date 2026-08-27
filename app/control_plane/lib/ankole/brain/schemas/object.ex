defmodule Ankole.Brain.Schemas.Object do
  @moduledoc """
  One current page of the instance knowledge space, identified by a stable
  slug. Body history lives in `brain_object_versions`; the retrieval
  projection lives in `brain_chunks`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "brain_objects" do
    field :slug, :string
    field :type, :string
    field :subtype, :string
    field :title, :string
    field :body, :string, default: ""
    field :meta, :map, default: %{}
    field :effective_date, :date
    field :content_hash, :string
    field :chunking_signature, :string
    field :emotional_weight, :float, default: 0.0
    field :emotional_weight_recomputed_at, :utc_datetime_usec
    field :salience_touched_at, :utc_datetime_usec
    field :last_retrieved_at, :utc_datetime_usec
    field :links_extracted_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    # `updated_at` means "logical page content last changed" and is written
    # only by the content write paths in `Objects`. Ecto's autoupdate would
    # bump it on every status writeback (salience recompute, extraction
    # stamps, chunk signatures), which permanently outruns the extraction
    # watermark and re-extracts the whole corpus every Dreaming round.
    field :updated_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: false)
  end

  @doc false
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(object, attrs) do
    object
    |> cast(attrs, [
      :slug,
      :type,
      :subtype,
      :title,
      :body,
      :meta,
      :effective_date,
      :content_hash,
      :chunking_signature,
      :emotional_weight,
      :emotional_weight_recomputed_at,
      :salience_touched_at,
      :last_retrieved_at,
      :links_extracted_at,
      :deleted_at
    ])
    |> validate_required([:slug, :type, :title])
    |> unique_constraint(:slug, name: :brain_objects_slug_key)
    |> check_constraint(:slug, name: :brain_objects_slug_present)
    |> check_constraint(:type, name: :brain_objects_type_present)
    |> check_constraint(:title, name: :brain_objects_title_present)
    |> check_constraint(:meta, name: :brain_objects_meta_object)
    |> check_constraint(:emotional_weight, name: :brain_objects_emotional_weight_range)
  end
end
