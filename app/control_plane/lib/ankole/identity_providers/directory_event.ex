defmodule Ankole.IdentityProviders.DirectoryEvent do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "identity_directory_events" do
    field :provider_id, :string
    field :event_id, :string
    field :event_type, :string
    field :external_ids, {:array, :string}, default: []
    field :reason, :string
    field :provider_time, :utc_datetime_usec

    field :status, Ecto.Enum,
      values: [:pending, :processed, :review_required, :dismissed],
      default: :pending

    field :last_error, :string
    field :processed_at, :utc_datetime_usec
    field :reviewed_by, Ankole.Ecto.PrincipalKey
    field :review_reason, :string
    timestamps()
  end
end
