defmodule Ankole.Conversations.InboundBatch do
  @moduledoc """
  Short-lived IM ingress grouping state before Signal creation.

  A row here is not actor work yet. It holds provider messages for one
  agent/binding/channel/thread until Conversations.Observe can decide whether they
  close as addressed input, ambient observation, or no Signal. Every row
  has one nullable direct reply target so unrelated references never merge.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Conversations.Conversation
  alias Ankole.Types.JSONValue

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(open finalized canceled)
  @modes ~w(neutral addressed)
  @policies ~w(ignore record_only may_intervene)

  schema "conversation_inbound_batches" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :binding_name, :string
    field :session_id, :string

    belongs_to :conversation, Conversation,
      foreign_key: :conversation_id,
      references: :id,
      type: Ecto.UUID

    field :provider_thread_id, :string, default: ""
    field :reply_to_provider_message_id, :string
    field :batch_state, :string, default: "open"
    field :mode, :string, default: "neutral"
    field :policy, :string
    field :requester_sender_key, :string
    field :entries, JSONValue, default: []
    field :available_at, :utc_datetime_usec
    field :batch_revision, :integer, default: 0

    timestamps()
  end

  @doc """
  Builds a changeset for inbound batch rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :session_id,
      :conversation_id,
      :provider_thread_id,
      :reply_to_provider_message_id,
      :batch_state,
      :mode,
      :policy,
      :requester_sender_key,
      :entries,
      :available_at,
      :batch_revision
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :session_id,
      :conversation_id,
      :reply_to_provider_message_id,
      :batch_state,
      :mode,
      :policy,
      :requester_sender_key
    ])
    |> normalize_thread_key()
    |> validate_required([
      :agent_uid,
      :binding_name,
      :session_id,
      :conversation_id,
      :batch_state,
      :mode,
      :policy,
      :entries,
      :available_at,
      :batch_revision
    ])
    |> validate_inclusion(:batch_state, @states)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:policy, @policies)
    |> validate_number(:batch_revision, greater_than_or_equal_to: 0)
    |> validate_entries()
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:agent_uid, :binding_name, :conversation_id, :provider_thread_id],
      name: :conversation_inbound_batches_open_index
    )
    |> check_constraint(:entries, name: :inbound_batches_entries_array)
    |> check_constraint(:batch_state, name: :inbound_batches_state_check)
    |> check_constraint(:mode, name: :inbound_batches_mode_check)
    |> check_constraint(:policy, name: :inbound_batches_policy_check)
  end

  defp validate_entries(changeset) do
    validate_change(changeset, :entries, fn
      :entries, entries when is_list(entries) -> []
      :entries, _value -> [entries: "must be a JSON array"]
    end)
  end

  defp normalize_thread_key(changeset) do
    put_change(
      changeset,
      :provider_thread_id,
      thread_key(get_field(changeset, :provider_thread_id))
    )
  end

  defp thread_key(nil), do: ""

  defp thread_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> ""
      trimmed -> trimmed
    end
  end

  defp thread_key(_value), do: ""
end
