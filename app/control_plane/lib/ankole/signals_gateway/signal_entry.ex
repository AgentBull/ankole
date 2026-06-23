defmodule Ankole.SignalsGateway.SignalEntry do
  @moduledoc """
  Latest observed provider entry mirror keyed by channel and provider entry id.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.SignalsGateway.JsonPayload
  alias Ankole.SignalsGateway.SignalChannel

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_entries" do
    belongs_to :channel, SignalChannel,
      foreign_key: :signal_channel_id,
      references: :id,
      type: :string,
      primary_key: true

    field :provider_entry_id, :string, primary_key: true
    field :text, :string
    field :formatted_content, :map, default: %{}
    field :attachments, {:array, :map}, default: []
    field :links, {:array, :map}, default: []
    field :author, :map, default: %{}
    field :mentions, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    field :raw_payload, :map, default: %{}
    field :provider_time, :utc_datetime_usec
    field :fallback_visible_text, :string
    field :reactions, :map, default: %{}
    field :raw_reaction_keys, :map, default: %{}
    field :document_id, :string
    field :search_text, :string
    field :metadata_text, :string
    field :content_hash, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :signal_channel_id,
      :provider_entry_id,
      :text,
      :formatted_content,
      :attachments,
      :links,
      :author,
      :mentions,
      :metadata,
      :raw_payload,
      :provider_time,
      :fallback_visible_text,
      :reactions,
      :raw_reaction_keys,
      :document_id,
      :search_text,
      :metadata_text,
      :content_hash,
      :first_seen_at,
      :last_seen_at
    ])
    |> normalize_blank([
      :signal_channel_id,
      :provider_entry_id,
      :text,
      :fallback_visible_text,
      :document_id,
      :search_text,
      :metadata_text,
      :content_hash
    ])
    |> validate_required([
      :signal_channel_id,
      :provider_entry_id,
      :formatted_content,
      :attachments,
      :links,
      :author,
      :mentions,
      :metadata,
      :raw_payload,
      :reactions,
      :raw_reaction_keys,
      :document_id,
      :first_seen_at,
      :last_seen_at
    ])
    |> foreign_key_constraint(:signal_channel_id)
    |> unique_constraint([:signal_channel_id, :provider_entry_id], name: :signal_entries_pkey)
    |> check_constraint(:provider_entry_id, name: :signal_entries_provider_entry_id_present)
    |> check_constraint(:document_id, name: :signal_entries_document_id_present)
    |> JsonPayload.validate_map(:formatted_content, allow_datetime: true)
    |> JsonPayload.validate_list(:attachments, allow_datetime: true)
    |> JsonPayload.validate_list(:links, allow_datetime: true)
    |> JsonPayload.validate_map(:author, allow_datetime: true)
    |> JsonPayload.validate_list(:mentions, allow_datetime: true)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> JsonPayload.validate_map(:raw_payload, allow_datetime: true)
    |> JsonPayload.validate_map(:reactions)
    |> JsonPayload.validate_map(:raw_reaction_keys)
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
