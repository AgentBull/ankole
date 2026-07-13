defmodule Ankole.Brain.Schemas.Cursor do
  @moduledoc "A durable scanner cursor keyed by a declared Brain material scope."

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "brain_cursors" do
    field :scope_kind, Ecto.Enum, values: [:channel, :principal], primary_key: true
    field :scope_key, :string, primary_key: true
    field :cursor_provider_time, :utc_datetime_usec
    field :cursor_source_entry_id, :string
    field :cursor_entry_observed_at, :utc_datetime_usec
    field :unavailable_reason, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [
      :scope_kind,
      :scope_key,
      :cursor_provider_time,
      :cursor_source_entry_id,
      :cursor_entry_observed_at,
      :unavailable_reason,
      :metadata
    ])
    |> normalize_blank([:scope_key, :cursor_source_entry_id])
    |> validate_required([:scope_kind, :scope_key, :metadata])
    |> JSONPayload.validate_map(:metadata)
    |> check_constraint(:scope_key, name: :brain_cursors_scope_key_present)
    |> check_constraint(:metadata, name: :brain_cursors_metadata_object)
  end
end
