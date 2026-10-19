defmodule Ankole.Pod.PageChange do
  @moduledoc """
  One entry of a document's operational-transform log.

  A `change` entry carries the `ChangeSet` that one editor session submitted:
  its client id, the batch number in that session, and the serialized change
  set. A `reset` entry replaces the whole document, for example a whole-page
  write from an Agent. The row is keyed by the revision after the entry.
  """

  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true

  import Ecto.Changeset

  alias Ankole.Ecto.ActorRef

  @primary_key false
  schema "page_changes" do
    field :page_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :revision, :integer, primary_key: true
    field :kind, Ecto.Enum, values: [:change, :reset]
    field :client_id, :string
    field :client_seq, :integer
    field :changes, Ankole.Ecto.JSONList
    field :author, ActorRef
    field :created_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :page_id,
      :revision,
      :kind,
      :client_id,
      :client_seq,
      :changes,
      :author,
      :created_at
    ])
    |> validate_required([:page_id, :revision, :kind, :author, :created_at])
    |> validate_number(:revision, greater_than: 0)
    |> validate_entry_shape()
    |> foreign_key_constraint(:page_id, name: :page_changes_tenant_id_page_id_fkey)
    |> unique_constraint(:revision, name: :page_changes_pkey)
    |> unique_constraint(:client_seq,
      name: :page_changes_tenant_id_page_id_client_id_client_seq_key
    )
    |> check_constraint(:kind, name: :page_changes_kind_check)
    |> check_constraint(:changes, name: :page_changes_entry_shape)
  end

  defp validate_entry_shape(changeset) do
    case get_field(changeset, :kind) do
      :change ->
        validate_required(changeset, [:client_id, :client_seq, :changes])

      :reset ->
        Enum.reduce([:client_id, :client_seq, :changes], changeset, fn field, result ->
          if is_nil(get_field(result, field)),
            do: result,
            else: add_error(result, field, "is not part of a reset entry")
        end)

      _other ->
        changeset
    end
  end
end
