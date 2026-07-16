defmodule Ankole.Brain.Schemas.RetainedSource do
  @moduledoc "Immutable bytes explicitly retained by a human for one Brain store."

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @capture_methods ~w(paste url file)

  @type t :: %__MODULE__{}

  schema "brain_retained_sources" do
    field :document_id, :string

    belongs_to :owner, Principal,
      foreign_key: :owner_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :store_key, :string
    field :capture_method, :string
    field :title, :string
    field :origin_locator, :string
    field :original_name, :string
    field :media_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :raw_content, :binary, load_in_query: false
    field :captured_by_uid, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :document_id,
      :owner_uid,
      :store_key,
      :capture_method,
      :title,
      :origin_locator,
      :original_name,
      :media_type,
      :byte_size,
      :sha256,
      :raw_content,
      :captured_by_uid
    ])
    |> normalize_blank([
      :document_id,
      :owner_uid,
      :store_key,
      :capture_method,
      :title,
      :origin_locator,
      :original_name,
      :media_type,
      :sha256,
      :captured_by_uid
    ])
    |> validate_required([
      :document_id,
      :owner_uid,
      :store_key,
      :capture_method,
      :title,
      :media_type,
      :byte_size,
      :sha256,
      :raw_content
    ])
    |> validate_inclusion(:capture_method, @capture_methods)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_format(:sha256, ~r/^[0-9a-f]{64}$/)
    |> foreign_key_constraint(:owner_uid)
    |> unique_constraint(:document_id, name: :brain_retained_sources_document_id_index)
    |> check_constraint(:document_id, name: :brain_retained_sources_document_id_check)
    |> check_constraint(:store_key, name: :brain_retained_sources_store_key_check)
    |> check_constraint(:capture_method, name: :brain_retained_sources_capture_method_check)
    |> check_constraint(:title, name: :brain_retained_sources_title_present)
    |> check_constraint(:media_type, name: :brain_retained_sources_media_type_present)
    |> check_constraint(:raw_content, name: :brain_retained_sources_content_consistent)
  end
end
