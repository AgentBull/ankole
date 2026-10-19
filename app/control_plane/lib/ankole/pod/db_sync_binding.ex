defmodule Ankole.Pod.DbSyncBinding do
  @moduledoc """
  The one external sync of a data table: the connector, its source query, the
  field map, the position of the last sync, and the AutomationJob that runs it.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset

  alias Ankole.Ecto.ActorRef

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  @statuses ~w(active paused)a

  schema "db_sync_bindings" do
    field :table_id, Ankole.Ecto.UUIDv7
    field :connector, :string
    field :source, :map
    field :field_map, :map
    field :cursor, :map
    field :automation_job_id, :integer
    field :status, Ecto.Enum, values: @statuses
    field :created_by, ActorRef
    field :created_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :id,
      :table_id,
      :connector,
      :source,
      :field_map,
      :cursor,
      :automation_job_id,
      :status,
      :created_by,
      :created_at
    ])
    |> validate_required([
      :table_id,
      :connector,
      :source,
      :field_map,
      :status,
      :created_by,
      :created_at
    ])
    |> foreign_key_constraint(:automation_job_id, name: :db_sync_bindings_automation_job_fkey)
    |> foreign_key_constraint(:table_id, name: :db_sync_bindings_tenant_id_table_id_fkey)
    |> unique_constraint(:table_id, name: :db_sync_bindings_table_id_key)
    |> check_constraint(:status, name: :db_sync_bindings_status_check)
  end
end
