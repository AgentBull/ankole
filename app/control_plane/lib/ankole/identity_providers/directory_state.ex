defmodule Ankole.IdentityProviders.DirectoryState do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "identity_directory_states" do
    field :provider_id, :string
    field :revision, :integer, default: 0

    field :status, Ecto.Enum,
      values: [:unverified, :syncing, :healthy, :review_required, :failed],
      default: :unverified

    field :scope_fingerprint, :string
    field :snapshot_fingerprint, :string
    field :approved_scope_fingerprint, :string
    field :member_uids, {:array, :string}, default: []
    field :missing_uids, {:array, :string}, default: []
    field :last_started_at, :utc_datetime_usec
    field :last_success_at, :utc_datetime_usec
    field :last_error, :string
    field :reviewed_by, Ankole.Ecto.PrincipalKey
    field :reviewed_at, :utc_datetime_usec
    field :review_reason, :string
    timestamps()
  end
end
