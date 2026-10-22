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

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations.Domain

  postgres do
    table("conversation_input_tombstones")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:conversation_id, "conversation_input_tombstones_conversation_id_fkey"}])

    unique_index_names([
      {[:tenant_id, :conversation_id, :provider_message_id], "conversation_input_tombstones_pkey"}
    ])
  end

  attributes do
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:provider_message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:tombstoned_until, :utc_datetime_usec, allow_nil?: false, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :record do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept([:conversation_id, :provider_message_id, :tombstoned_until])
      upsert?(true)
      upsert_fields([:tombstoned_until])
    end

    destroy :expire do
      transaction?(false)
      require_atomic?(true)
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(tombstoned_until <= ^arg(:now))))
    end
  end
end
