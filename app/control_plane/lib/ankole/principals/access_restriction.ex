defmodule Ankole.Principals.AccessRestriction do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "human_access_restrictions" do
    field :principal_uid, Ankole.Ecto.PrincipalKey
    field :source, :string
    field :reason, :string
    field :operation_id, :string
    field :provider_time, :utc_datetime_usec
    field :recovery_verified_at, :utc_datetime_usec
    field :cleared_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(restriction, attrs) do
    restriction
    |> cast(attrs, [:principal_uid, :source, :reason, :operation_id, :provider_time])
    |> validate_required([:principal_uid, :source, :reason, :operation_id])
    |> validate_length(:source, max: 200)
    |> validate_length(:reason, max: 2000)
    |> validate_length(:operation_id, max: 200)
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:principal_uid, name: :human_access_restrictions_active_index)
  end
end
