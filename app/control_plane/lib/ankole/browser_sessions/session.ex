defmodule Ankole.BrowserSessions.Session do
  @moduledoc false
  use Ankole.Schema, tenancy: :site
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "browser_sessions" do
    field :revision, :integer, default: 0
    field :logout_revision, :integer, default: 0
    field :active_authentication_id, Ankole.Ecto.UUIDv7
    field :active_tenant_id, Ankole.Ecto.UUIDv7
    field :expires_at, :utc_datetime_usec
    timestamps()
  end
end
