defmodule Ankole.Principals.ExternalIdentity do
  @moduledoc """
  Durable binding from an external provider subject to a Principal.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  schema "principal_external_identities" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :kind, Ecto.Enum,
      values: [:platform_subject, :channel_actor, :login_subject, :outbound_actor]

    field :provider, :string
    field :adapter, :string
    field :channel_id, :string
    field :external_id, :string
    field :verified_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for external identity rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(external_identity, attrs) do
    external_identity
    |> cast(attrs, [
      :principal_uid,
      :kind,
      :provider,
      :adapter,
      :channel_id,
      :external_id,
      :verified_at,
      :metadata
    ])
    |> normalize_blank([:provider, :adapter, :channel_id, :external_id])
    |> validate_required([:principal_uid, :kind, :external_id, :metadata])
    |> JSONPayload.validate_map(:metadata)
    |> validate_format(:provider, @provider_format)
    |> validate_kind_shape()
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:external_id, name: :principal_external_identities_channel_actor_index)
    |> unique_constraint(:external_id,
      name: :principal_external_identities_provider_identity_index
    )
    |> check_constraint(:kind, name: :principal_external_identities_shape)
    |> check_constraint(:provider, name: :principal_external_identities_provider_format)
    |> check_constraint(:metadata, name: :principal_external_identities_metadata_object)
  end

  defp validate_kind_shape(changeset) do
    case get_field(changeset, :kind) do
      :channel_actor ->
        changeset
        |> validate_required([:adapter, :channel_id])
        |> validate_absent(:provider)

      kind when kind in [:platform_subject, :login_subject, :outbound_actor] ->
        changeset
        |> validate_required([:provider])
        |> validate_absent(:adapter)
        |> validate_absent(:channel_id)

      _kind ->
        changeset
    end
  end

  defp validate_absent(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> add_error(changeset, field, "must be blank")
    end
  end
end
