defmodule Ankole.Brain.Schemas.EntryBlock do
  @moduledoc "A separately attributable, independently editable knowledge block."

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "brain_entry_blocks" do
    belongs_to :entry, Entry

    belongs_to :owner, Principal,
      foreign_key: :owner_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :store_key, :string
    field :position, :integer
    field :body, :string
    field :author_kind, Ecto.Enum, values: [:human, :agent, :dreaming]

    belongs_to :author, Principal,
      foreign_key: :author_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :embedding, Pgvector.Ecto.Vector
    field :embedding_dimensions, :integer
    field :embedding_model_agent_uid, :string
    field :embedding_state, Ecto.Enum, values: [:pending, :synced, :failed], default: :pending
    field :embedding_error, :string
    field :lock_version, :integer, default: 1

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(block, attrs) do
    block
    |> cast(
      attrs,
      [
        :entry_id,
        :owner_uid,
        :store_key,
        :position,
        :body,
        :author_kind,
        :author_uid,
        :embedding,
        :embedding_dimensions,
        :embedding_model_agent_uid,
        :embedding_state,
        :embedding_error
      ],
      empty_values: []
    )
    |> normalize_blank([
      :owner_uid,
      :store_key,
      :body,
      :author_uid,
      :embedding,
      :embedding_model_agent_uid,
      :embedding_error
    ])
    |> validate_required([:entry_id, :owner_uid, :store_key, :position, :body, :author_kind])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_embedding()
    |> apply_constraints()
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(block, attrs) do
    block
    |> cast(attrs, [:body, :author_kind, :author_uid], empty_values: [])
    |> normalize_blank([:body, :author_uid])
    |> validate_required([:body, :author_kind])
    |> invalidate_embedding()
    |> optimistic_lock(:lock_version)
    |> apply_constraints()
  end

  defp invalidate_embedding(changeset) do
    if get_change(changeset, :body) do
      changeset
      |> put_change(:embedding, nil)
      |> put_change(:embedding_dimensions, nil)
      |> put_change(:embedding_model_agent_uid, nil)
      |> put_change(:embedding_state, :pending)
      |> put_change(:embedding_error, nil)
    else
      changeset
    end
  end

  defp validate_embedding(changeset) do
    validate_change(changeset, :embedding_dimensions, fn :embedding_dimensions, dimensions ->
      if is_integer(dimensions) and dimensions > 0,
        do: [],
        else: [embedding_dimensions: "must be greater than zero"]
    end)
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:owner_uid)
    |> foreign_key_constraint(:author_uid)
    |> foreign_key_constraint(:entry_id, name: :brain_entry_blocks_entry_scope_fkey)
    |> unique_constraint([:entry_id, :position], name: :brain_entry_blocks_entry_position_index)
    |> check_constraint(:store_key, name: :brain_entry_blocks_store_key_check)
    |> check_constraint(:position, name: :brain_entry_blocks_position_nonnegative)
    |> check_constraint(:body, name: :brain_entry_blocks_body_present)
    |> check_constraint(:embedding_dimensions,
      name: :brain_entry_blocks_embedding_dimensions_positive
    )
    |> check_constraint(:embedding_state, name: :brain_entry_blocks_embedding_state_consistent)
    |> check_constraint(:lock_version, name: :brain_entry_blocks_lock_version_positive)
  end
end
