defmodule Ankole.SignalsGateway.SignalChannel do
  @moduledoc """
  Latest observed provider channel mirror.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.SignalsGateway.JsonPayload
  alias Ankole.SignalsGateway.SignalEntry

  @primary_key {:id, :string, []}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_channels" do
    field :kind, Ecto.Enum,
      values: [:im_dm, :im_group, :webhook_endpoint, :issue, :alert_stream, :unknown],
      default: :unknown

    field :reply_mode, Ecto.Enum, values: [:none, :channel, :entry], default: :none
    field :name, :string
    field :title, :string
    field :visibility, :string
    field :metadata, :map, default: %{}
    field :raw_payload, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    has_many :entries, SignalEntry, foreign_key: :signal_channel_id, references: :id

    timestamps()
  end

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :id,
      :kind,
      :reply_mode,
      :name,
      :title,
      :visibility,
      :metadata,
      :raw_payload,
      :first_seen_at,
      :last_seen_at
    ])
    |> normalize_blank([:id, :name, :title, :visibility])
    |> validate_required([
      :id,
      :kind,
      :reply_mode,
      :metadata,
      :raw_payload,
      :first_seen_at,
      :last_seen_at
    ])
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> JsonPayload.validate_map(:raw_payload, allow_datetime: true)
    |> unique_constraint(:id, name: :signal_channels_pkey)
    |> check_constraint(:id, name: :signal_channels_id_present)
    |> check_constraint(:metadata, name: :signal_channels_metadata_object)
    |> check_constraint(:raw_payload, name: :signal_channels_raw_payload_object)
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
end
