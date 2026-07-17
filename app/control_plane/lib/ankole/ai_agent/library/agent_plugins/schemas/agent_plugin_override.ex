defmodule Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2, normalize_lower: 2]

  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @identifier ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  schema "agent_plugin_overrides" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:agent_plugin_id, :string)
    field(:enabled, :boolean)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:agent_uid, :agent_plugin_id, :enabled])
    |> normalize_blank([:agent_uid, :agent_plugin_id])
    |> normalize_lower([:agent_plugin_id])
    |> validate_required([:agent_uid, :agent_plugin_id, :enabled])
    |> validate_format(:agent_plugin_id, @identifier)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :agent_plugin_id],
      name: :agent_plugin_overrides_agent_plugin_index
    )
    |> check_constraint(:agent_plugin_id,
      name: :agent_plugin_overrides_agent_plugin_id_format
    )
  end
end
