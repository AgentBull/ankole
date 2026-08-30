defmodule Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry do
  @moduledoc """
  Agent-owned writable library-container entry.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2, normalize_lower: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # The only agent-owned files implemented by this table are the runtime docs
  # seeded per agent. Skill lessons are semantic rows in `agent_skill_lessons`.
  @source_kinds ~w(soul mission design confidentiality_policy)

  schema "agent_library_container_entries" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:path, :string)
    field(:source_kind, :string)
    field(:content, :string)
    field(:content_hash, :string)
    field(:metadata, :map, default: %{})
    field(:deleted_at, :utc_datetime_usec)

    timestamps()
  end

  @doc """
  Builds a changeset for agent library container entry rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :agent_uid,
      :path,
      :source_kind,
      :content,
      :content_hash,
      :metadata,
      :deleted_at
    ])
    |> normalize_blank([:agent_uid, :path, :source_kind, :content_hash])
    |> normalize_lower(:source_kind)
    |> normalize_path(:path)
    |> validate_required([:agent_uid, :path, :source_kind, :metadata])
    |> validate_inclusion(:source_kind, @source_kinds)
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    # Uniqueness is over *live* rows only (the backing index is partial on
    # `deleted_at IS NULL`). Deletes are soft, so a previously deleted path can be
    # re-created, and `Library.upsert_agent_text_entry_in_tx/2` un-deletes via the
    # same partial-index conflict target.
    |> unique_constraint([:agent_uid, :path],
      name: :agent_library_container_entries_active_path_index
    )
    |> check_constraint(:path, name: :agent_library_container_entries_path_present)
    |> check_constraint(:source_kind,
      name: :agent_library_container_entries_source_kind_check
    )
    |> check_constraint(:metadata, name: :agent_library_container_entries_metadata_object)
  end

  defp normalize_path(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> normalize_virtual_path(value)
      value -> value
    end)
  end

  defp normalize_virtual_path(value) do
    value
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\/+/, "")
    |> String.replace(~r/\/+/, "/")
  end
end
