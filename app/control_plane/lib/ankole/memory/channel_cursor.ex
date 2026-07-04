defmodule Ankole.Memory.ChannelCursor do
  @moduledoc """
  Per-channel Layer B scanner cursor.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "memory_channel_cursors" do
    belongs_to :channel, Channel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string,
      primary_key: true

    field :cursor_provider_time, :utc_datetime_usec
    field :cursor_source_entry_id, :string
    field :cursor_entry_observed_at, :utc_datetime_usec
    field :unavailable_reason, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [
      :signal_channel_id,
      :cursor_provider_time,
      :cursor_source_entry_id,
      :cursor_entry_observed_at,
      :unavailable_reason,
      :metadata
    ])
    |> normalize_blank([:signal_channel_id, :cursor_source_entry_id, :unavailable_reason])
    |> validate_required([:signal_channel_id, :metadata])
    |> foreign_key_constraint(:signal_channel_id)
    |> JsonPayload.validate_map(:metadata)
    |> check_constraint(:metadata, name: :memory_channel_cursors_metadata_object)
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
