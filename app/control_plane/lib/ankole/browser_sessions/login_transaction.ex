defmodule Ankole.BrowserSessions.LoginTransaction do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "browser_login_transactions" do
    field :browser_id, Ankole.Ecto.UUIDv7
    field :generation, :integer
    field :purpose, Ecto.Enum, values: [:console, :oauth]

    field :status, Ecto.Enum,
      values: [:pending, :authenticated, :consumed, :cancelled],
      default: :pending

    field :request, :map, default: %{}
    field :provider_id, :string
    field :upstream_state, :string
    field :redirect_uri, :string
    field :password_ticket, :map
    field :authentication, :map
    field :expires_at, :utc_datetime_usec
    timestamps()
  end
end
