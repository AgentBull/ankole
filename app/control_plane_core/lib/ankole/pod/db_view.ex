defmodule Ankole.Pod.DbView do
  @moduledoc """
  One view of a data table. `config` holds the filters, sorts, groups, and the
  presentation of the view type.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  @types ~w(grid kanban gallery)a

  schema "db_views" do
    field :table_id, Ankole.Ecto.UUIDv7
    field :name, :string
    field :position, :string
    field :type, Ecto.Enum, values: @types
    field :config, :map, default: %{}
    field :version, :integer, default: 1
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(view, attrs) do
    view
    |> cast(attrs, [:id, :table_id, :name, :position, :type, :config, :version])
    |> validate_required([:table_id, :name, :position, :type, :config, :version])
    |> validate_number(:version, greater_than: 0)
    |> foreign_key_constraint(:table_id, name: :db_views_tenant_id_table_id_fkey)
    |> check_constraint(:type, name: :db_views_type_check)
  end
end
