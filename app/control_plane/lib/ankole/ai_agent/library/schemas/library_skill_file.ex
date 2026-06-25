defmodule Ankole.AIAgent.Library.Schemas.LibrarySkillFile do
  @moduledoc """
  Canonical file belonging to a first-party skill bundle.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIAgent.Library.Schemas.LibrarySkill
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "library_skill_files" do
    belongs_to :skill, LibrarySkill,
      foreign_key: :skill_name,
      references: :skill_name,
      type: :string

    field :path, :string
    field :content, :string
    field :content_hash, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(file, attrs) do
    file
    |> cast(attrs, [:skill_name, :path, :content, :content_hash, :metadata], empty_values: [])
    |> normalize_blank([:skill_name, :path, :content_hash])
    |> normalize_skill_name(:skill_name)
    |> normalize_path(:path)
    |> validate_required([:skill_name, :path, :content_hash, :metadata])
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:skill_name)
    |> unique_constraint([:skill_name, :path], name: :library_skill_files_skill_path_index)
    |> check_constraint(:path, name: :library_skill_files_path_present)
    |> check_constraint(:content_hash, name: :library_skill_files_content_hash_present)
    |> check_constraint(:metadata, name: :library_skill_files_metadata_object)
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

  defp normalize_skill_name(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end

  defp normalize_path(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> normalize_virtual_path(value)
      value -> value
    end)
  end

  defp normalize_virtual_path(value) do
    value
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\/+/, "")
    |> String.replace(~r/\/+/, "/")
  end
end
