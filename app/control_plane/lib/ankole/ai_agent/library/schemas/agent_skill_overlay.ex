defmodule Ankole.AIAgent.Library.Schemas.AgentSkillOverlay do
  @moduledoc """
  Per-agent skill overlay stored as semantic data, not as a workspace file.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @skill_name_format ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  schema "agent_skill_overlays" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string
    )

    field(:skill_name, :string)

    field(:overlay_json, :map, default: %{})
    field(:content_hash, :string)
    field(:deleted_at, :utc_datetime_usec)

    timestamps()
  end

  @doc false
  def changeset(overlay, attrs) do
    overlay
    |> cast(attrs, [:agent_uid, :skill_name, :overlay_json, :content_hash, :deleted_at])
    |> normalize_blank([:agent_uid, :skill_name, :content_hash])
    |> normalize_lower([:agent_uid, :skill_name])
    |> validate_required([:agent_uid, :skill_name, :overlay_json, :content_hash])
    |> validate_format(:skill_name, @skill_name_format)
    |> JsonPayload.validate_map(:overlay_json, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :skill_name],
      name: :agent_skill_overlays_active_skill_index
    )
    |> check_constraint(:skill_name, name: :agent_skill_overlays_skill_name_format)
    |> check_constraint(:overlay_json, name: :agent_skill_overlays_overlay_object)
    |> check_constraint(:content_hash, name: :agent_skill_overlays_content_hash_present)
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
