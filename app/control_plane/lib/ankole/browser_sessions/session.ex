defmodule Ankole.BrowserSessions.Session do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "browser_sessions" do
    field :generation, :integer, default: 1
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :admin_auth, :map
    field :oauth_auth, :map
    timestamps()
  end
end
