defmodule Ankole.OIDC.LogoutRequest do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "oidc_logout_requests" do
    field :browser_id, Ankole.Ecto.UUIDv7
    field :browser_generation, :integer
    field :client_id, Ankole.Ecto.UUIDv7
    field :redirect_uri, :string
    field :state, :string
    field :expires_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    timestamps()
  end
end
