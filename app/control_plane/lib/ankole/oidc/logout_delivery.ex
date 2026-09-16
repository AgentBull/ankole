defmodule Ankole.OIDC.LogoutDelivery do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "oidc_logout_deliveries" do
    field :session_id, Ankole.Ecto.UUIDv7
    field :endpoint, :string

    field :status, Ecto.Enum,
      values: [:pending, :delivering, :delivered, :failed],
      default: :pending

    field :attempt_count, :integer, default: 0
    field :last_attempt_at, :utc_datetime_usec
    field :next_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :deadline, :utc_datetime_usec
    field :last_error, :string
    timestamps()
  end
end
