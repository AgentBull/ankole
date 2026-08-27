defmodule Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
  @moduledoc """
  One leased process-guardrail checklist item for one (agent, skill).

  A row's content is immutable: correcting a lesson retires the old row and
  writes a new one. Only the lease fields (`review_after`, `checked_release`,
  `checked_skill_hash`) change in place on renewal. Rows are never hard
  deleted, so the table is its own audit trail.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2, normalize_lower: 2]

  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @skill_name_format ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @author_kinds ~w(dreaming human)
  @retire_reasons ~w(human_revoked lapsed obsolete)

  schema "agent_skill_lessons" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:skill_name, :string)
    field(:content, :string)
    field(:author_kind, :string)

    belongs_to(:author, Principal,
      foreign_key: :author_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:evidence_job_ids, {:array, :integer}, default: [])
    field(:checked_release, :string)
    field(:checked_skill_hash, :string)
    field(:review_after, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)
    field(:retire_reason, :string)

    timestamps()
  end

  @doc "Returns the allowed retire reasons."
  @spec retire_reasons() :: [String.t()]
  def retire_reasons, do: @retire_reasons

  @doc """
  Builds a changeset for skill lesson rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [
      :agent_uid,
      :skill_name,
      :content,
      :author_kind,
      :author_uid,
      :evidence_job_ids,
      :checked_release,
      :checked_skill_hash,
      :review_after,
      :retired_at,
      :retire_reason
    ])
    |> normalize_blank([:agent_uid, :skill_name, :content, :author_kind, :author_uid])
    |> normalize_lower(:skill_name)
    |> validate_required([:agent_uid, :skill_name, :content, :author_kind])
    |> validate_format(:skill_name, @skill_name_format)
    |> validate_inclusion(:author_kind, @author_kinds)
    |> validate_inclusion(:retire_reason, @retire_reasons)
    |> validate_lease_shape()
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:author_uid)
    |> check_constraint(:author_kind, name: :agent_skill_lessons_author_kind)
    |> check_constraint(:skill_name, name: :agent_skill_lessons_skill_name_format)
    |> check_constraint(:content, name: :agent_skill_lessons_content_present)
    |> check_constraint(:retire_reason, name: :agent_skill_lessons_retire_shape)
    |> check_constraint(:review_after, name: :agent_skill_lessons_lease_shape)
  end

  defp validate_lease_shape(changeset) do
    case get_field(changeset, :author_kind) do
      "dreaming" ->
        changeset
        |> validate_required([:review_after, :checked_release, :checked_skill_hash])
        |> validate_length(:evidence_job_ids, min: 1)

      "human" ->
        if is_nil(get_field(changeset, :review_after)),
          do: changeset,
          else: add_error(changeset, :review_after, "human lessons carry no lease")

      _other ->
        changeset
    end
  end
end
