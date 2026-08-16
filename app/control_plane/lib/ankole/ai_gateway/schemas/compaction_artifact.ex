defmodule Ankole.AIGateway.Schemas.CompactionArtifact do
  @moduledoc """
  Stored compaction artifact for AIGateway history compaction.

  This table is the only durable source of compaction output. Message rows may
  point at an artifact through a checkpoint, but the summary and retained tail
  live here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Ecto.JSONPayload
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

    field(:content, Ankole.Types.JSONValue, default: %{})

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
    |> JSONPayload.validate_map(:content, allow_datetime: true)
    |> validate_content_contract()
    |> foreign_key_constraint(:subject_uid)
    |> foreign_key_constraint(:conversation_id)
    |> check_constraint(:content, name: :ai_gateway_compaction_artifacts_content_object)
  end

  @doc """
  Tells whether `binding` can tie a version 3 upstream artifact to its
  provider row: non-empty `provider_row_id`, `provider_updated_at`, and
  `model` strings.
  """
  @spec valid_upstream_binding?(term()) :: boolean()
  def valid_upstream_binding?(%{
        "provider_row_id" => provider_row_id,
        "provider_updated_at" => provider_updated_at,
        "model" => model
      }) do
    Enum.all?([provider_row_id, provider_updated_at, model], fn value ->
      is_binary(value) and String.trim(value) != ""
    end)
  end

  def valid_upstream_binding?(_binding), do: false

  defp validate_content_contract(changeset) do
    content = get_field(changeset, :content)

    cond do
      not is_map(content) ->
        add_error(changeset, :content, "must be a JSON object")

      true ->
        validate_versioned_content(changeset, content)
    end
  end

  defp validate_versioned_content(changeset, %{"version" => 2} = content) do
    cond do
      not is_map(Map.get(content, "summary")) ->
        add_error(changeset, :content, "version 2 must include a summary object")

      not is_list(Map.get(content, "output")) ->
        add_error(changeset, :content, "version 2 must include output items")

      true ->
        changeset
    end
  end

  defp validate_versioned_content(changeset, %{"version" => 3} = content) do
    cond do
      Map.get(content, "source") != "upstream" ->
        add_error(changeset, :content, "version 3 source must be upstream")

      not valid_upstream_binding?(Map.get(content, "binding")) ->
        add_error(changeset, :content, "version 3 must include a binding object")

      not is_list(Map.get(content, "output")) or Map.get(content, "output") == [] ->
        add_error(changeset, :content, "version 3 must include output items")

      true ->
        changeset
    end
  end

  defp validate_versioned_content(changeset, _content),
    do: add_error(changeset, :content, "must use version 2 or 3")
end
