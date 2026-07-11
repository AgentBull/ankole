defmodule Ankole.AIAgent.Library.Schemas.LibraryBuiltinSyncState do
  @moduledoc """
  Content hash cursor for builtin skill sync.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "library_builtin_sync_states" do
    field :name, :string, primary_key: true
    field :content_hash, :string
    field :synced_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for library built-in sync state rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:name, :content_hash, :synced_at, :metadata])
    |> normalize_blank([:name, :content_hash])
    |> validate_required([:name, :content_hash, :metadata])
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> unique_constraint(:name, name: :library_builtin_sync_states_pkey)
    |> check_constraint(:name, name: :library_builtin_sync_states_name_present)
    |> check_constraint(:content_hash, name: :library_builtin_sync_states_content_hash_present)
    |> check_constraint(:metadata, name: :library_builtin_sync_states_metadata_object)
  end
end
