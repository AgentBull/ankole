defmodule Ankole.Pod.DbField do
  @moduledoc """
  One field of a data table: its type, its JSON configuration, and the version
  that a write uses to compare and set the field.

  At most one field of a table is primary. Field names are unique in a table.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  @types ~w(text number select datetime checkbox user attachment auto_number link formula
            created_at updated_at created_by updated_by)a

  schema "db_fields" do
    field :table_id, Ankole.Ecto.UUIDv7
    field :name, :string
    field :position, :string
    field :type, Ecto.Enum, values: @types
    field :config, :map, default: %{}
    field :is_primary, :boolean, default: false
    field :version, :integer, default: 1
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(field, attrs) do
    field
    |> cast(attrs, [:id, :table_id, :name, :position, :type, :config, :is_primary, :version])
    |> validate_required([:table_id, :name, :position, :type, :config, :is_primary, :version])
    |> validate_number(:version, greater_than: 0)
    |> foreign_key_constraint(:table_id, name: :db_fields_tenant_id_table_id_fkey)
    |> unique_constraint(:name, name: :db_fields_name_index)
    |> unique_constraint(:is_primary, name: :db_fields_one_primary_index)
    |> check_constraint(:type, name: :db_fields_type_check)
  end
end
