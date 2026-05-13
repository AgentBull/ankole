defmodule BullX.Runtime.AgenticLoop.Session do
  @moduledoc false

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Agent

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "agent_sessions" do
    belongs_to :agent, Agent,
      foreign_key: :agent_principal_id,
      references: :principal_id,
      define_field: false

    field :agent_principal_id, :binary_id
    field :conversation_key, :string
    field :current_leaf_message_id, :binary_id
    field :ended_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) when is_map(attrs) do
    session
    |> cast(attrs, [
      :agent_principal_id,
      :conversation_key,
      :current_leaf_message_id,
      :ended_at,
      :metadata
    ])
    |> normalize_blank([:conversation_key])
    |> validate_required([:agent_principal_id, :conversation_key, :metadata])
    |> validate_map(:metadata)
    |> foreign_key_constraint(:agent_principal_id)
    |> foreign_key_constraint(:current_leaf_message_id,
      name: :agent_sessions_current_leaf_session_fk
    )
    |> unique_constraint([:agent_principal_id, :conversation_key],
      name: :agent_sessions_one_active_per_conversation
    )
    |> check_constraint(:conversation_key, name: :agent_sessions_conversation_key_present)
    |> check_constraint(:metadata, name: :agent_sessions_metadata_object)
  end
end
