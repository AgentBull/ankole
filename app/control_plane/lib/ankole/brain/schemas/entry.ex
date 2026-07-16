defmodule Ankole.Brain.Schemas.Entry do
  @moduledoc """
  Current structured knowledge about one named subject.

  Markdown is rendered from this row, its blocks, and its relations. It is not
  persisted as a second source of truth.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.EntryRelation
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "brain_entries" do
    belongs_to :owner, Principal,
      foreign_key: :owner_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :store_key, :string
    field :name, :string
    field :type, :string
    field :summary, :string, default: ""
    field :aliases, {:array, :string}, default: []
    field :properties, :map, default: %{}
    field :search_text, :string
    field :lock_version, :integer, default: 1

    has_many :blocks, EntryBlock
    has_many :outgoing_relations, EntryRelation, foreign_key: :source_entry_id
    has_many :incoming_relations, EntryRelation, foreign_key: :target_entry_id

    timestamps()
  end

  @doc "Builds a new knowledge entry and its derived search document."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:owner_uid, :store_key, :name, :type, :summary, :aliases, :properties],
      empty_values: []
    )
    |> normalize_blank([:owner_uid, :store_key, :name, :type])
    |> validate_required([:owner_uid, :store_key, :name, :type, :aliases, :properties])
    |> validate_aliases()
    |> JSONPayload.validate_map(:properties)
    |> put_search_text()
    |> apply_constraints()
  end

  @doc "Builds an optimistic metadata update for an existing entry."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:name, :type, :summary, :aliases, :properties], empty_values: [])
    |> normalize_blank([:name, :type])
    |> validate_required([:name, :type, :aliases, :properties])
    |> validate_aliases()
    |> JSONPayload.validate_map(:properties)
    |> put_search_text()
    |> optimistic_lock(:lock_version)
    |> apply_constraints()
  end

  @doc "Returns whether the complete projection must be threat-scanned before commit."
  @spec protected_projection?(t()) :: boolean()
  def protected_projection?(%__MODULE__{type: type, properties: properties}) do
    type == "agent_system_pinned_memo" or
      (is_map(properties) and present_string?(properties["channel_id"] || properties[:channel_id]))
  end

  defp put_search_text(changeset) do
    text =
      [
        get_field(changeset, :name),
        get_field(changeset, :type),
        get_field(changeset, :summary),
        Enum.join(get_field(changeset, :aliases) || [], " ")
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    put_change(changeset, :search_text, text)
  end

  defp validate_aliases(changeset) do
    validate_change(changeset, :aliases, fn :aliases, aliases ->
      cond do
        not is_list(aliases) ->
          [aliases: "must be a list"]

        Enum.any?(aliases, &(not present_string?(&1))) ->
          [aliases: "must contain non-blank strings"]

        length(Enum.uniq(aliases)) != length(aliases) ->
          [aliases: "must not contain duplicates"]

        true ->
          []
      end
    end)
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:owner_uid)
    |> unique_constraint([:owner_uid, :store_key, :name],
      name: :brain_entries_owner_store_name_index
    )
    |> unique_constraint(:owner_uid, name: :brain_entries_public_pinned_memo_index)
    |> unique_constraint(:owner_uid, name: :brain_entries_public_curation_guide_index)
    |> unique_constraint(:properties, name: :brain_entries_channel_identity_index)
    |> check_constraint(:store_key, name: :brain_entries_store_key_check)
    |> check_constraint(:name, name: :brain_entries_name_present)
    |> check_constraint(:type, name: :brain_entries_type_present)
    |> check_constraint(:search_text, name: :brain_entries_search_text_present)
    |> check_constraint(:properties, name: :brain_entries_properties_object)
    |> check_constraint(:lock_version, name: :brain_entries_lock_version_positive)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
