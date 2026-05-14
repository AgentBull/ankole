defmodule BullX.Principals.ExternalIdentity do
  @moduledoc """
  Durable mapping from an external subject to a BullX Principal.

  Metadata is for provider context and troubleshooting data only. It must not
  carry credentials or private tokens.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Principal

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principal_external_identities" do
    belongs_to :principal, Principal

    field :kind, Ecto.Enum, values: [:channel_actor, :login_subject, :outbound_actor]
    field :provider, :string
    field :adapter, :string
    field :channel_id, :string
    field :external_id, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(external_identity, attrs) do
    external_identity
    |> cast(attrs, [
      :principal_id,
      :kind,
      :provider,
      :adapter,
      :channel_id,
      :external_id,
      :metadata
    ])
    |> normalize_blank([:provider, :adapter, :channel_id, :external_id])
    |> validate_required([:principal_id, :kind, :metadata])
    |> validate_map(:metadata)
    |> validate_kind_fields()
    |> foreign_key_constraint(:principal_id)
    |> unique_constraint(:external_id, name: :principal_external_identities_channel_actor_index)
    |> unique_constraint(:external_id, name: :principal_external_identities_login_subject_index)
    |> unique_constraint(:external_id, name: :principal_external_identities_outbound_actor_index)
    |> check_constraint(:kind, name: :principal_external_identities_channel_actor_required)
    |> check_constraint(:kind, name: :principal_external_identities_provider_subject_required)
    |> check_constraint(:metadata, name: :principal_external_identities_metadata_object)
  end

  defp validate_kind_fields(changeset) do
    case get_field(changeset, :kind) do
      :channel_actor ->
        validate_required(changeset, [:adapter, :channel_id, :external_id])

      kind when kind in [:login_subject, :outbound_actor] ->
        validate_required(changeset, [:provider, :external_id])

      _kind ->
        changeset
    end
  end
end
