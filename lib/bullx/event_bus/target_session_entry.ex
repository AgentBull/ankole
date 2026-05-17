defmodule BullX.EventBus.TargetSessionEntry do
  @moduledoc """
  Weak runtime side-channel entry for an accepted Event.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "target_session_entries" do
    field :entry_seq, :integer, read_after_writes: true
    field :target_session_id, :binary_id
    field :event_source, :string
    field :event_id, :string
    field :dedupe_hash, :string
    field :cloud_event, :map
    field :routing_context, :map
    field :appended_at, :utc_datetime_usec
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :target_session_id,
      :event_source,
      :event_id,
      :dedupe_hash,
      :cloud_event,
      :routing_context,
      :appended_at
    ])
    |> validate_required([
      :target_session_id,
      :event_source,
      :event_id,
      :dedupe_hash,
      :cloud_event,
      :routing_context,
      :appended_at
    ])
    |> unique_constraint(:dedupe_hash)
  end
end
