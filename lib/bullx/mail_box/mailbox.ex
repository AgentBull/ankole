defmodule BullX.MailBox.Mailbox do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.MailBox.{Entry, Session}

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "mailboxes" do
    field :receiver_type, :string
    field :receiver_ref, :string
    field :metadata, :map, default: %{}

    has_many :sessions, Session
    has_many :entries, Entry

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(mailbox, attrs) when is_map(attrs) do
    mailbox
    |> cast(attrs, [:receiver_type, :receiver_ref, :metadata])
    |> validate_required([:receiver_type, :receiver_ref, :metadata])
    |> validate_non_empty(:receiver_type)
    |> validate_non_empty(:receiver_ref)
    |> validate_json_object(:metadata)
    |> unique_constraint([:receiver_type, :receiver_ref])
    |> check_constraint(:receiver_type, name: :mailboxes_receiver_type_present)
    |> check_constraint(:receiver_ref, name: :mailboxes_receiver_ref_present)
    |> check_constraint(:metadata, name: :mailboxes_metadata_object)
  end

  defp validate_non_empty(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_binary(value) and String.trim(value) != "" do
        true -> []
        false -> [{field, "must be a non-empty string"}]
      end
    end)
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case BullX.JSON.json_object?(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end
end
