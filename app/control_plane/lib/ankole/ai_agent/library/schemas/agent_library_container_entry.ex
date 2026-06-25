defmodule Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry do
  @moduledoc """
  Agent-owned writable library-container entry.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # What kind of agent-owned file this row backs. `soul`/`mission` are the
  # persona docs seeded per agent, `skill_append` is the per-agent override
  # spliced into a shared skill; the rest are other writable surfaces the agent
  # accumulates over its lifetime.
  @source_kinds ~w(soul mission skill_append setting memory system user computer)

  schema "agent_library_container_entries" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :path, :string
    field :source_kind, :string
    field :content, :string
    field :content_hash, :string
    field :metadata, :map, default: %{}
    field :deleted_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
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
    |> normalize_lower([:agent_uid, :source_kind])
    |> normalize_path(:path)
    |> validate_required([:agent_uid, :path, :source_kind, :metadata])
    |> validate_inclusion(:source_kind, @source_kinds)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
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

  defp normalize_lower(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_lower(&2, &1))
  end

  defp normalize_lower(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
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
