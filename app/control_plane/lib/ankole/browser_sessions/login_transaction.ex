defmodule Ankole.BrowserSessions.LoginTransaction do
  @moduledoc false
  use Ankole.Schema, tenancy: :site
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "browser_login_transactions" do
    field :tenant_id, Ankole.Ecto.UUIDv7
    field :browser_id, Ankole.Ecto.UUIDv7
    field :started_revision, :integer
    field :purpose, Ecto.Enum, values: [:console, :oauth, :pod, :site]
    field :mode, Ecto.Enum, values: [:replace, :add], default: :replace
    field :expected_authentication_id, Ankole.Ecto.UUIDv7
    field :authentication_id, Ankole.Ecto.UUIDv7
    field :authentication_revision, :integer
    field :csrf_token, :string

    field :status, Ecto.Enum,
      values: [:pending, :authenticated, :consumed, :cancelled],
      default: :pending

    field :request, :map, default: %{}
    field :provider_id, :string
    field :upstream_state, :string
    field :redirect_uri, :string
    field :password_ticket, :map
    field :expires_at, :utc_datetime_usec
    timestamps()
  end
end
