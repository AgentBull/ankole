defmodule Ankole.AIAgent.Library.Schemas.AgentSkillOverlay do
  @moduledoc """
  Per-agent skill overlay stored as semantic data, not as a workspace file.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2, normalize_lower: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @skill_name_format ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  schema "agent_skill_overlays" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:skill_name, :string)

    field(:overlay_json, :map, default: %{})
    field(:content_hash, :string)
    field(:deleted_at, :utc_datetime_usec)

    timestamps()
  end

  @doc """
  Builds a changeset for agent skill overlay rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(overlay, attrs) do
    overlay
    |> cast(attrs, [:agent_uid, :skill_name, :overlay_json, :content_hash, :deleted_at])
    |> normalize_blank([:agent_uid, :skill_name, :content_hash])
    |> normalize_lower(:skill_name)
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
end
