defmodule Ankole.Pod.DbTable do
  @moduledoc """
  One data table of a Database page.

  `data_version` increases with every record write, `record_count` keeps the
  number of records, and `next_auto_number` supplies the next value of every
  `auto_number` field.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "db_tables" do
    field :page_id, Ankole.Ecto.UUIDv7
    field :name, :string
    field :position, :string
    field :data_version, :integer, default: 0
    field :record_count, :integer, default: 0
    field :next_auto_number, :integer, default: 1
  end

  @type t :: %__MODULE__{}

  def record_limit, do: 100_000

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(table, attrs) do
    table
    |> cast(attrs, [
      :id,
      :page_id,
      :name,
      :position,
      :data_version,
      :record_count,
      :next_auto_number
    ])
    |> validate_required([
      :page_id,
      :name,
      :position,
      :data_version,
      :record_count,
      :next_auto_number
    ])
    |> validate_number(:data_version, greater_than_or_equal_to: 0)
    |> validate_number(:record_count, greater_than_or_equal_to: 0)
    |> validate_number(:next_auto_number, greater_than: 0)
    |> foreign_key_constraint(:page_id, name: :db_tables_tenant_id_page_id_fkey)
    |> unique_constraint(:id, name: :db_tables_pkey)
  end
end
