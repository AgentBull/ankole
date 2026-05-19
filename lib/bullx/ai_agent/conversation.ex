defmodule BullX.AIAgent.Conversation do
  @moduledoc """
  Durable AIAgent conversation continuity.

  A Conversation is business state owned by AIAgent. It is separate from
  TargetSession runtime state and may be touched by many TargetSessions over
  time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.AIAgent.Message
  alias BullX.Principals.Principal

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "conversations" do
    belongs_to :agent_principal, Principal
    field :conversation_key, :string
    belongs_to :current_leaf_message, Message
    field :ended_at, :utc_datetime_usec
    field :generation, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :agent_principal_id,
      :conversation_key,
      :current_leaf_message_id,
      :ended_at,
      :generation,
      :metadata
    ])
    |> validate_required([:agent_principal_id, :conversation_key, :generation, :metadata])
    |> validate_json_object(:generation)
    |> validate_json_object(:metadata)
    |> foreign_key_constraint(:agent_principal_id)
    |> foreign_key_constraint(:current_leaf_message_id,
      name: :conversations_current_leaf_same_conversation_fkey
    )
    |> unique_constraint([:agent_principal_id, :conversation_key],
      name: :conversations_active_agent_key_index
    )
    |> check_constraint(:generation, name: :conversations_generation_object)
    |> check_constraint(:metadata, name: :conversations_metadata_object)
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end
end
