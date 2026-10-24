defmodule Ankole.Pod.DbRecord do
  @moduledoc """
  One Database record with independent field versions and immutable creation facts.

  The users of a Database define the fields of `data` at runtime. The Pod
  Database subsystem (`Ankole.Pod.Database`, its `Write`, `Records`, and
  `Schema` modules, `Ankole.Pod.Query`, `Ankole.Pod.Copy`, and
  `Ankole.Pod.Values`) owns `db_records` through this Ecto schema. It is not an
  Ash resource.
  """
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true

  import Ecto.Changeset

  alias Ankole.Ecto.{ActorRef, JSONPayload}

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  schema "db_records" do
    field(:table_id, Ankole.Ecto.UUIDv7, primary_key: true)
    field(:data, :map, default: %{})
    field(:versions, :map, default: %{})
    field(:created_by, ActorRef)
    field(:created_at, :utc_datetime_usec)
    field(:updated_by, ActorRef)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @values [:data, :versions, :updated_by, :updated_at]

  @doc "Gives the changeset that creates one record of a table."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :table_id,
      :data,
      :versions,
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
    |> validate_json([:data, :versions])
    |> foreign_key_constraint(:table_id, name: :db_records_tenant_id_table_id_fkey)
    |> unique_constraint([:table_id, :id], name: :db_records_pkey)
    |> check_constraint(:data, name: :db_records_value_objects)
  end

  @doc """
  Gives the changeset that replaces the values and versions of one record.

  The identity and the creation facts do not change: the changeset rejects
  every other input.
  """
  @spec update_values_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_values_changeset(%__MODULE__{} = record, attrs) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in @values))
    |> Enum.reduce(cast(record, attrs, @values), &add_error(&2, &1, "cannot be changed"))
    |> validate_required(@values)
    |> validate_json([:data, :versions])
    |> check_constraint(:data, name: :db_records_value_objects)
  end

  # The JSON maps keep the durable JSON contract of the Ankole JSON attributes.
  defp validate_json(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      with {:ok, value} <- fetch_change(changeset, field),
           {:error, reason} <- JSONPayload.normalize_map(value) do
        add_error(changeset, field, "must be a JSON object: #{JSONPayload.reason_text(reason)}")
      else
        {:ok, map} -> put_change(changeset, field, map)
        :error -> changeset
      end
    end)
  end
end
