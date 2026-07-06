defmodule Ankole.SignalsGateway.InputTombstone do
  @moduledoc """
  Short-lived guard that prevents late receive redelivery after provider removal.

  Problem it solves: providers do not order removal events against the original
  receive. A "message deleted" event can race ahead of (or arrive interleaved
  with) a retried "message received" for the same entry, which would otherwise
  resurrect a message the human already retracted. When the gateway processes a
  removal event it drops a tombstone keyed by
  `{agent_uid, binding_name, signal_channel_id, source_entry_id}`; a later
  receive for that key is dropped while the tombstone is live (see
  `SignalsGateway.active_tombstone?/3`).

  Why a TTL and not forever: this only needs to outlive provider redelivery
  windows, not be a permanent denylist. The TTL (24h, set by the gateway) is
  swept by the cleanup job so the table self-empties. A tombstone is a transient
  ordering guard, not a record of the deletion.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.Channel

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_gateway_input_tombstones" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :binding_name, :string, primary_key: true

    belongs_to :channel, Channel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string,
      primary_key: true

    field :source_entry_id, :string, primary_key: true
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
      :agent_uid,
      :binding_name,
      :signal_channel_id,
      :source_entry_id,
      :tombstoned_until
    ])
    |> normalize_blank([:agent_uid, :binding_name, :signal_channel_id, :source_entry_id])
    |> validate_required([
      :agent_uid,
      :binding_name,
      :signal_channel_id,
      :source_entry_id,
      :tombstoned_until
    ])
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:signal_channel_id)
    |> unique_constraint(
      [:agent_uid, :binding_name, :signal_channel_id, :source_entry_id],
      name: :signal_gateway_input_tombstones_pkey
    )
  end
end
