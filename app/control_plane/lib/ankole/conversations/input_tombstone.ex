defmodule Ankole.Conversations.InputTombstone do
  @moduledoc """
  Short-lived guard that prevents late receive redelivery after provider removal.

  Problem it solves: providers do not order removal events against the original
  receive. A "message deleted" event can race ahead of (or arrive interleaved
  with) a retried "message received" for the same entry, which would otherwise
  resurrect a message the human already retracted. When the gateway processes a
  removal event it drops a tombstone keyed by
  `{conversation_id, provider_message_id}` within the tenant; a later receive
  through any Agent or binding is dropped while the tombstone is live (see
  `Conversations.Observe.active_tombstone?/3`).

  Why a TTL and not forever: this only needs to outlive provider redelivery
  windows, not be a permanent denylist. The TTL (24h, set by the gateway) is
  swept by the cleanup job so the table self-empties. A tombstone is a transient
  ordering guard, not a record of the deletion.
  """

  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Conversations.Conversation

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "conversation_input_tombstones" do
    belongs_to :conversation, Conversation,
      foreign_key: :conversation_id,
      references: :id,
      type: Ecto.UUID,
      primary_key: true

    field :provider_message_id, :string, primary_key: true
    # Wall-clock expiry of the guard. A receive arriving at-or-before this
    # instant is dropped; after it, the cleanup job deletes the row and normal
    # ingress resumes for that entry.
    field :tombstoned_until, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Builds a changeset for input tombstone rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [
      :conversation_id,
      :provider_message_id,
      :tombstoned_until
    ])
    |> normalize_blank([:conversation_id, :provider_message_id])
    |> validate_required([
      :conversation_id,
      :provider_message_id,
      :tombstoned_until
    ])
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint(
      [:conversation_id, :provider_message_id],
      name: :conversation_input_tombstones_pkey
    )
  end
end
