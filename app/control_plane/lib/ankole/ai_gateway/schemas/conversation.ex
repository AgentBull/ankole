defmodule Ankole.AIGateway.Schemas.Conversation do
  @moduledoc """
  Durable conversation spine for one principal subject, owned by AIGateway.

  The conversation row owns only identity, scope, and metadata. It does not store
  a run lease or continuation pointer: the authoritative base for an in-flight
  run is the `ai_gateway_messages.previous_message_id` of the generating row.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "ai_gateway_conversations" do
    belongs_to(:subject, Principal,
      foreign_key: :subject_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:conversation_key, :string)
    field(:ended_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @doc """
  Builds a changeset for conversation rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:subject_uid, :conversation_key, :ended_at, :metadata])
    |> normalize_blank([:subject_uid, :conversation_key])
    |> validate_required([:subject_uid, :conversation_key, :metadata])
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:subject_uid)
    # Only one *active* (not yet `ended_at`) conversation may exist per
    # (subject, conversation_key). The backing index is partial on `ended_at IS
    # NULL`, so an ended session can be superseded by a new one under the same
    # key. This collision is what `Conversations.ensure_conversation_in_tx/4` relies on
    # to make concurrent first-input safe: it inserts, and on conflict refetches
    # the row the racing writer created.
    |> unique_constraint([:subject_uid, :conversation_key],
      name: :ai_gateway_conversations_active_key_index
    )
    |> check_constraint(:metadata, name: :ai_gateway_conversations_metadata_object)
  end
end
