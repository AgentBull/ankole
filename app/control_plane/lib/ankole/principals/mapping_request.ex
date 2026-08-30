defmodule Ankole.Principals.MappingRequest do
  @moduledoc """
  One unmapped signal sender waiting for an operator to bind it to a Principal.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  schema "identity_mapping_requests" do
    field :provider, :string
    field :external_id, :string
    field :display_name, :string
    field :email, :string
    field :mobile, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for mapping request rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:provider, :external_id, :display_name, :email, :mobile, :metadata])
    |> normalize_blank([:provider, :external_id, :display_name, :email, :mobile])
    |> validate_required([:provider, :external_id, :metadata])
    |> JSONPayload.validate_map(:metadata)
    |> validate_format(:provider, @provider_format)
    |> unique_constraint(:external_id, name: :identity_mapping_requests_subject_index)
    |> check_constraint(:provider, name: :identity_mapping_requests_provider_format)
    |> check_constraint(:metadata, name: :identity_mapping_requests_metadata_object)
  end
end
