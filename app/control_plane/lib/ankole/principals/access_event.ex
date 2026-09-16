defmodule Ankole.Principals.AccessEvent do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "human_access_events" do
    field :principal_uid, Ankole.Ecto.PrincipalKey
    field :operation_id, :string
    field :source, :string
    field :action, :string
    field :reason, :string
    field :actor_uid, Ankole.Ecto.PrincipalKey
    field :previous_status, Ecto.Enum, values: [:active, :disabled]
    field :status, Ecto.Enum, values: [:active, :disabled]
    field :access_version, :integer
    field :provider_time, :utc_datetime_usec
    field :details, :map, default: %{}
    timestamps(updated_at: false)
  end
end
