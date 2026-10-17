defmodule Ankole.BrowserSessions.Authentication do
  @moduledoc false
  use Ankole.Schema, tenancy: :site

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "browser_authentications" do
    field :browser_id, Ankole.Ecto.UUIDv7
    field :tenant_id, Ankole.Ecto.UUIDv7
    field :provider_id, :string
    field :subject_id, :string
    field :external_id, :string
    field :purpose, Ecto.Enum, values: [:console, :oauth, :pod, :site]
    field :console_authenticated, :boolean, default: false
    field :revision, :integer
    field :auth_time, :integer
    field :csrf_token, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end
end
