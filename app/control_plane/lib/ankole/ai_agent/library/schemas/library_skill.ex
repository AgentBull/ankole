defmodule Ankole.AIAgent.Library.Schemas.LibrarySkill do
  @moduledoc """
  Canonical first-party skill catalog row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.SignalsGateway.JsonPayload

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]
  @skill_name_format ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  schema "library_skills" do
    field :skill_name, :string, primary_key: true
    field :description, :string
    field :default_enabled, :boolean, default: true
    field :metadata, :map, default: %{}
    field :content_hash, :string
    field :synced_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :skill_name,
      :description,
      :default_enabled,
      :metadata,
      :content_hash,
      :synced_at
    ])
    |> normalize_blank([:skill_name, :description, :content_hash])
    |> normalize_name(:skill_name)
    |> validate_required([:skill_name, :description, :default_enabled, :metadata, :content_hash])
    |> validate_format(:skill_name, @skill_name_format)
    |> validate_length(:description, min: 1, max: 1024)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> unique_constraint(:skill_name, name: :library_skills_pkey)
    |> check_constraint(:skill_name, name: :library_skills_skill_name_format)
    |> check_constraint(:description, name: :library_skills_description_present)
    |> check_constraint(:metadata, name: :library_skills_metadata_object)
    |> check_constraint(:content_hash, name: :library_skills_content_hash_present)
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

  defp normalize_name(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end
end
