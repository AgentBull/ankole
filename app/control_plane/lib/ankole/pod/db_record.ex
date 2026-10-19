defmodule Ankole.Pod.DbRecord do
  @moduledoc """
  One record of a data table.

  `data` maps a field ID to that field's value, and `versions` maps a field ID
  to the version of that value, so two people can write different fields of one
  record without a conflict. `external_id` is the identity of the record in the
  external system that a sync binding copied it from.
  """

  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true

  import Ecto.Changeset

  alias Ankole.Ecto.ActorRef

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  schema "db_records" do
    field :table_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :data, :map, default: %{}
    field :versions, :map, default: %{}
    field :external_id, :string
    field :created_by, ActorRef
    field :created_at, :utc_datetime_usec
    field :updated_by, ActorRef
    field :updated_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :table_id,
      :data,
      :versions,
      :external_id,
      :created_by,
      :created_at,
      :updated_by,
      :updated_at
    ])
    |> validate_required([
      :table_id,
      :data,
      :versions,
      :created_by,
      :created_at,
      :updated_by,
      :updated_at
    ])
    |> foreign_key_constraint(:table_id, name: :db_records_tenant_id_table_id_fkey)
    |> unique_constraint(:id, name: :db_records_pkey)
    |> unique_constraint(:external_id, name: :db_records_external_index)
  end
end
