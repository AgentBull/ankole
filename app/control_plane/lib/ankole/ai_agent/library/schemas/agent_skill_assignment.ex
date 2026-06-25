defmodule Ankole.AIAgent.Library.Schemas.AgentSkillAssignment do
  @moduledoc """
  Agent-local enablement override for a canonical skill.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIAgent.Library.Schemas.LibrarySkill
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_skill_assignments" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    belongs_to :skill, LibrarySkill,
      foreign_key: :skill_name,
      references: :skill_name,
      type: :string

    field :enabled, :boolean
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:agent_uid, :skill_name, :enabled, :metadata])
    |> normalize_blank([:agent_uid, :skill_name])
    |> normalize_lower([:agent_uid, :skill_name])
    |> validate_required([:agent_uid, :skill_name, :enabled, :metadata])
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:skill_name)
    |> unique_constraint([:agent_uid, :skill_name],
      name: :agent_skill_assignments_agent_skill_index
    )
    |> check_constraint(:metadata, name: :agent_skill_assignments_metadata_object)
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

  defp normalize_lower(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_lower(&2, &1))
  end

  defp normalize_lower(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
