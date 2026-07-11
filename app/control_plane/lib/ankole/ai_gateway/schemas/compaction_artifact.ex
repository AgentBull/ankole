defmodule Ankole.AIGateway.Schemas.CompactionArtifact do
  @moduledoc """
  Stored compaction artifact for OpenResponses `/responses/compact`.

  This table is the only durable source of compaction output. Message rows may
  point at an artifact through a checkpoint, but the summary and retained tail
  live here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Ecto.JsonPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "ai_gateway_compaction_artifacts" do
    belongs_to(:subject, Principal,
      foreign_key: :subject_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    belongs_to(:conversation, Conversation, type: :binary_id)

    field(:content, Ankole.Types.JsonValue, default: %{})

    timestamps()
  end

  @doc """
  Builds a changeset for compaction artifacts.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:subject_uid, :conversation_id, :content])
    |> validate_required([:subject_uid, :content])
    |> JsonPayload.validate_map(:content, allow_datetime: true)
    |> validate_content_contract()
    |> foreign_key_constraint(:subject_uid)
    |> foreign_key_constraint(:conversation_id)
    |> check_constraint(:content, name: :ai_gateway_compaction_artifacts_content_object)
  end

  defp validate_content_contract(changeset) do
    content = get_field(changeset, :content)

    cond do
      not is_map(content) ->
        add_error(changeset, :content, "must be a JSON object")

      Map.get(content, "version") not in [1, 2] ->
        add_error(changeset, :content, "must use version 1 or 2")

      not is_map(Map.get(content, "summary")) ->
        add_error(changeset, :content, "must include a summary object")

      not is_list(Map.get(content, "output")) ->
        add_error(changeset, :content, "must include output items")

      true ->
        changeset
    end
  end
end
