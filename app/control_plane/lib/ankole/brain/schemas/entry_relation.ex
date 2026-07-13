defmodule Ankole.Brain.Schemas.EntryRelation do
  @moduledoc "A directed, explicitly asserted relation between knowledge entries."

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "brain_entry_relations" do
    belongs_to :owner, Principal,
      foreign_key: :owner_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :store_key, :string
    belongs_to :source_entry, Entry
    field :predicate, :string
    belongs_to :target_entry, Entry
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:owner_uid, :store_key, :source_entry_id, :predicate, :target_entry_id])
    |> normalize_blank([:owner_uid, :store_key, :predicate])
    |> validate_required([:owner_uid, :store_key, :source_entry_id, :predicate, :target_entry_id])
    |> foreign_key_constraint(:owner_uid)
    |> foreign_key_constraint(:source_entry_id)
    |> foreign_key_constraint(:target_entry_id)
    |> unique_constraint([:source_entry_id, :predicate, :target_entry_id],
      name: :brain_entry_relations_unique_edge_index
    )
    |> check_constraint(:store_key, name: :brain_entry_relations_store_key_check)
    |> check_constraint(:predicate, name: :brain_entry_relations_predicate_present)
    |> check_constraint(:target_entry_id, name: :brain_entry_relations_no_self_edge)
  end
end
