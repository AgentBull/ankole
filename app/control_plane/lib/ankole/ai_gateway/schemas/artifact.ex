defmodule Ankole.AIGateway.Schemas.Artifact do
  @moduledoc """
  Binary artifact owned by an AIGateway subject.

  Payloads are excluded from ordinary queries so model catalogs, file listings,
  and stored message reads never copy image bytes accidentally.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @kinds ~w(uploaded_file generated_image)

  schema "ai_gateway_artifacts" do
    belongs_to(:subject, Principal,
      foreign_key: :subject_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    belongs_to(:message, Message, type: :binary_id)

    field(:kind, :string)
    field(:provider_item_id, :string)
    field(:filename, :string)
    field(:purpose, :string)
    field(:mime_type, :string)
    field(:byte_size, :integer)
    field(:sha256, :binary)
    field(:payload, :binary, load_in_query: false)
    field(:expires_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :id,
      :subject_uid,
      :message_id,
      :kind,
      :provider_item_id,
      :filename,
      :purpose,
      :mime_type,
      :byte_size,
      :sha256,
      :payload,
      :expires_at
    ])
    |> validate_required([:subject_uid, :kind, :mime_type, :byte_size, :sha256, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_length(:sha256, is: 32, count: :bytes)
    |> validate_contract()
    |> foreign_key_constraint(:subject_uid)
    |> foreign_key_constraint(:message_id)
    |> check_constraint(:kind, name: :ai_gateway_artifacts_kind_check)
    |> check_constraint(:payload, name: :ai_gateway_artifacts_payload_size_check)
    |> check_constraint(:sha256, name: :ai_gateway_artifacts_sha256_size_check)
    |> check_constraint(:purpose, name: :ai_gateway_artifacts_uploaded_file_contract)
    |> check_constraint(:purpose, name: :ai_gateway_artifacts_generated_image_contract)
  end

  defp validate_contract(changeset) do
    kind = get_field(changeset, :kind)
    payload = get_field(changeset, :payload)
    byte_size = get_field(changeset, :byte_size)

    changeset
    |> validate_payload_size(payload, byte_size)
    |> validate_kind_contract(kind)
  end

  defp validate_payload_size(changeset, payload, byte_size)
       when is_binary(payload) and is_integer(byte_size) and byte_size(payload) == byte_size,
       do: changeset

  defp validate_payload_size(changeset, _payload, _byte_size),
    do: add_error(changeset, :byte_size, "must match payload size")

  defp validate_kind_contract(changeset, "uploaded_file") do
    changeset
    |> validate_required([:filename, :purpose])
    |> validate_inclusion(:purpose, ["vision"])
    |> validate_change(:message_id, fn :message_id, value ->
      if is_nil(value), do: [], else: [message_id: "must be empty for uploaded files"]
    end)
  end

  defp validate_kind_contract(changeset, "generated_image") do
    case get_field(changeset, :purpose) do
      nil -> changeset
      _purpose -> add_error(changeset, :purpose, "must be empty for generated images")
    end
  end

  defp validate_kind_contract(changeset, _kind), do: changeset
end
