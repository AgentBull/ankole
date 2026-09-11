defmodule Ankole.OIDC.Session do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "oidc_sessions" do
    field :client_id, Ankole.Ecto.UUIDv7
    field :principal_uid, Ankole.Ecto.PrincipalKey
    field :browser_id, Ankole.Ecto.UUIDv7
    field :browser_generation, :integer
    field :access_version, :integer
    field :provider_id, :string
    field :auth_time, :integer
    field :expires_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end
end
