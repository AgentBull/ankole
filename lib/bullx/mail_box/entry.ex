defmodule BullX.MailBox.Entry do
  @moduledoc """
  Durable delivery record for one CloudEvents mail item and one Agent Receiver.

  `BullX.IMGateway` stores the external-world message once; MailBox stores one
  entry per matched Receiver. The entry owns delivery metadata such as
  attention, queue key, and idempotency key, but not the business facts that the
  Agent later derives from processing the mail.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.Principals.Agent

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @attention [:addressed, :ambient, :command, :action, :lifecycle, :system]

  @type t :: %__MODULE__{}

  schema "mailbox_entries" do
    field :entry_seq, :integer, read_after_writes: true

    belongs_to :agent, Agent, foreign_key: :agent_uid, references: :uid, type: :string

    field :queue_key, :string
    field :attention, Ecto.Enum, values: @attention
    field :cloud_event, BullX.Ecto.JSONB
    field :idempotency_key, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) when is_map(attrs) do
    entry
    |> cast(attrs, [
      :agent_uid,
      :queue_key,
      :attention,
      :cloud_event,
      :idempotency_key
    ])
    |> validate_required([
      :agent_uid,
      :queue_key,
      :attention,
      :cloud_event,
      :idempotency_key
    ])
    |> validate_non_empty(:queue_key)
    |> validate_json_object(:cloud_event)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :idempotency_key])
    |> check_constraint(:queue_key, name: :mailbox_entries_queue_key_present)
    |> check_constraint(:cloud_event, name: :mailbox_entries_cloud_event_object)
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case BullX.JSON.json_object?(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end

  defp validate_non_empty(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_binary(value) and String.trim(value) != "" do
        true -> []
        false -> [{field, "must be a non-empty string"}]
      end
    end)
  end
end
