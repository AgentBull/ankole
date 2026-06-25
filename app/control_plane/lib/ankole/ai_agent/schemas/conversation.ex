defmodule Ankole.AIAgent.Schemas.Conversation do
  @moduledoc """
  Durable conversation spine for one agent session.

  `generation` is the active-turn lease shared with ActorRuntime. The transcript
  remains in AI-agent tables while the computer owns the local AI loop execution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "ai_agent_conversations" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :conversation_key, :string
    field :ended_at, :utc_datetime_usec
    field :generation, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:agent_uid, :conversation_key, :ended_at, :generation, :metadata])
    |> normalize_blank([:agent_uid, :conversation_key])
    |> normalize_uid(:agent_uid)
    |> validate_required([:agent_uid, :conversation_key, :generation, :metadata])
    |> JsonPayload.validate_map(:generation, allow_datetime: true)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    # Only one *active* (not yet `ended_at`) conversation may exist per
    # (agent, conversation_key). The backing index is partial on `ended_at IS
    # NULL`, so an ended session can be superseded by a new one under the same
    # key. This collision is what `AIAgent.ensure_conversation_in_tx/3` relies on
    # to make concurrent first-input safe: it inserts, and on conflict refetches
    # the row the racing writer created.
    |> unique_constraint([:agent_uid, :conversation_key],
      name: :ai_agent_conversations_active_key_index
    )
    |> check_constraint(:generation, name: :ai_agent_conversations_generation_object)
    |> check_constraint(:metadata, name: :ai_agent_conversations_metadata_object)
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

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
