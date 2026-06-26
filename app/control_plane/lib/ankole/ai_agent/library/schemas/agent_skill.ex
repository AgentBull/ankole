defmodule Ankole.AIAgent.Library.Schemas.AgentSkill do
  @moduledoc """
  Per-agent skill registry row.

  Both builtin and agent-installed skills are filesystem skill bundles. This
  row records the agent-visible registry, enablement, prompt-facing semantics,
  and the latest XXH3 file observation. File contents stay on disk.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @skill_name_format ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @source_kinds ~w(builtin installed)

  schema "agent_skills" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string
    )

    field(:skill_name, :string)
    field(:source_kind, :string)
    field(:relative_path, :string)
    field(:enabled, :boolean)
    field(:default_enabled, :boolean)
    field(:description, :string)
    field(:metadata, :map, default: %{})
    field(:content_hash, :string)
    field(:synced_at, :utc_datetime_usec)

    timestamps()
  end

  @doc false
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :agent_uid,
      :skill_name,
      :source_kind,
      :relative_path,
      :enabled,
      :default_enabled,
      :description,
      :metadata,
      :content_hash,
      :synced_at
    ])
    |> normalize_blank([
      :agent_uid,
      :skill_name,
      :source_kind,
      :relative_path,
      :description,
      :content_hash
    ])
    |> normalize_lower([:agent_uid, :skill_name, :source_kind])
    |> normalize_relative_path(:relative_path)
    |> validate_required([
      :agent_uid,
      :skill_name,
      :source_kind,
      :relative_path,
      :enabled,
      :default_enabled,
      :description,
      :metadata,
      :content_hash
    ])
    |> validate_format(:skill_name, @skill_name_format)
    |> validate_inclusion(:source_kind, @source_kinds)
    |> validate_length(:description, min: 1, max: 1024)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :skill_name], name: :agent_skills_agent_skill_index)
    |> check_constraint(:skill_name, name: :agent_skills_skill_name_format)
    |> check_constraint(:source_kind, name: :agent_skills_source_kind_check)
    |> check_constraint(:relative_path, name: :agent_skills_relative_path_present)
    |> check_constraint(:description, name: :agent_skills_description_present)
    |> check_constraint(:metadata, name: :agent_skills_metadata_object)
    |> check_constraint(:content_hash, name: :agent_skills_content_hash_present)
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

  defp normalize_relative_path(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        value
        |> String.replace("\\", "/")
        |> String.replace(~r/\A\/+/, "")
        |> String.replace(~r/\/+/, "/")

      value ->
        value
    end)
  end
end
