defmodule Ankole.Brain.Schemas.SchemaCalibrationDomain do
  @moduledoc """
  One Take calibration domain of the instance ontology.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  schema "brain_schema_calibration_domains" do
    field :name, :string
    field :aggregator, :string
    field :pack_name, :string
    field :created_at, :utc_datetime_usec
  end
end
