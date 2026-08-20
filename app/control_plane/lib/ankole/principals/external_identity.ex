defmodule Ankole.Principals.ExternalIdentity do
  @moduledoc """
  Durable binding from a provider-scoped external subject to a Principal.
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

    field :provider, :string
    field :external_id, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for external identity rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(external_identity, attrs) do
    external_identity
    |> cast(attrs, [:principal_uid, :provider, :external_id, :metadata])
    |> normalize_blank([:provider, :external_id])
    |> validate_required([:principal_uid, :provider, :external_id, :metadata])
    |> JSONPayload.validate_map(:metadata)
    |> validate_format(:provider, @provider_format)
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:external_id,
      name: :principal_external_identities_provider_identity_index
    )
    |> check_constraint(:provider, name: :principal_external_identities_provider_format)
    |> check_constraint(:metadata, name: :principal_external_identities_metadata_object)
  end
end
