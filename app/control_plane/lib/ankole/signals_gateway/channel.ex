defmodule Ankole.SignalsGateway.Channel do
  @moduledoc """
  Latest observed provider channel mirror.

  A "channel" is the provider-side container an entry lives in (an IM DM/group, a
  webhook endpoint, an issue, an alert stream). This row is a pure external-fact
  mirror: it records what the provider currently looks like, separate from any
  agent execution. `reply_mode` (how the agent is allowed to respond — channel
  post vs. threaded entry reply) is read by the outbox to choose a send
  operation. Keyed by the provider-native channel id, so writes upsert rather
  than insert per event.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.AuthZ.Group
  alias Ankole.SignalsGateway.Entry

  @primary_key {:id, :string, []}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_gateway_channels" do
    field :kind, Ecto.Enum,
      values: [:im_dm, :im_group, :webhook_endpoint, :issue, :alert_stream, :unknown],
      default: :unknown

    field :reply_mode, Ecto.Enum, values: [:none, :channel, :entry], default: :none
    field :name, :string
    field :visibility, :string
    belongs_to :principal_group, Group, type: :binary_id
    field :metadata, :map, default: %{}
    field :raw_payload, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    # Operator- or member-set standing orders for ambient behavior in this
    # channel, and the watermark up to which ambient batches were judged.
    # These are runtime channel policy and cursor state, not provider facts.
    field :ambient_standing_orders, :string
    field :ambient_standing_orders_set_by, :string
    field :ambient_standing_orders_updated_at, :utc_datetime_usec
    field :ambient_judged_until, :utc_datetime_usec

    has_many :entries, Entry, foreign_key: :signal_channel_id, references: :id

    timestamps()
  end

  @doc """
  Builds a changeset for signal channel rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :id,
      :kind,
      :reply_mode,
      :name,
      :visibility,
      :principal_group_id,
      :metadata,
      :raw_payload,
      :first_seen_at,
      :last_seen_at
    ])
    |> normalize_blank([:id, :name, :visibility])
    |> validate_required([
      :id,
      :kind,
      :reply_mode,
      :metadata,
      :raw_payload,
      :first_seen_at,
      :last_seen_at
    ])
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> JSONPayload.validate_map(:raw_payload, allow_datetime: true)
    |> foreign_key_constraint(:principal_group_id)
    |> unique_constraint(:id, name: :signal_gateway_channels_pkey)
    |> check_constraint(:id, name: :signal_gateway_channels_id_present)
    |> check_constraint(:principal_group_id,
      name: :signal_gateway_channels_principal_group_kind
    )
    |> check_constraint(:metadata, name: :signal_gateway_channels_metadata_object)
    |> check_constraint(:raw_payload, name: :signal_gateway_channels_raw_payload_object)
  end
end
