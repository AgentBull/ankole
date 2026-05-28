defmodule BullX.MailBox.Entry do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.MailBox.{Mailbox, Session}

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses [:pending, :leased, :processed, :discarded, :failed]
  @attention [:addressed, :ambient, :command, :action, :lifecycle, :system]

  @type t :: %__MODULE__{}

  schema "mailbox_entries" do
    field :entry_seq, :integer, read_after_writes: true

    belongs_to :mailbox, Mailbox
    belongs_to :session, Session, foreign_key: :mailbox_session_id

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attention, Ecto.Enum, values: @attention
    field :cloud_event, BullX.Ecto.JSONB
    field :reply_address, :map
    field :available_at, :utc_datetime_usec
    field :dedupe_hash, :binary
    field :coalesce_key, :string
    field :lease_holder, :string
    field :lease_expires_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :safe_error, :map

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) when is_map(attrs) do
    entry
    |> cast(attrs, [
      :mailbox_id,
      :mailbox_session_id,
      :status,
      :attention,
      :cloud_event,
      :reply_address,
      :available_at,
      :dedupe_hash,
      :coalesce_key,
      :lease_holder,
      :lease_expires_at,
      :attempts,
      :safe_error
    ])
    |> validate_required([
      :mailbox_id,
      :status,
      :attention,
      :cloud_event,
      :available_at,
      :dedupe_hash,
      :attempts
    ])
    |> validate_json_object(:cloud_event)
    |> validate_optional_json_object(:reply_address)
    |> validate_optional_json_object(:safe_error)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:mailbox_id)
    |> foreign_key_constraint(:mailbox_session_id)
    |> unique_constraint([:mailbox_id, :dedupe_hash])
    |> check_constraint(:cloud_event, name: :mailbox_entries_cloud_event_object)
    |> check_constraint(:reply_address, name: :mailbox_entries_reply_address_object)
    |> check_constraint(:safe_error, name: :mailbox_entries_safe_error_object)
    |> check_constraint(:attempts, name: :mailbox_entries_attempts_nonnegative)
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case BullX.JSON.json_object?(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end

  defp validate_optional_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_nil(value) or BullX.JSON.json_object?(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end
end
