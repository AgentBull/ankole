defmodule Ankole.Principals.ExternalIdentity do
  @moduledoc """
  Durable binding from an external provider subject to a Principal.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Kernel, as: AnkoleKernel
  alias Ankole.Principals.Principal

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  schema "principal_external_identities" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string

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

  @doc false
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
    |> ensure_id()
    |> normalize_blank([:provider, :adapter, :channel_id, :external_id])
    |> normalize_uid(:principal_uid)
    |> validate_required([:principal_uid, :kind, :external_id, :metadata])
    |> validate_map(:metadata)
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

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, AnkoleKernel.gen_uuid_v7())
      _id -> changeset
    end
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

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end
end
