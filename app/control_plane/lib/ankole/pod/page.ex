defmodule Ankole.Pod.Page do
  @moduledoc """
  One node of the page tree, its revision, and its trash state.

  A root page has no `parent_id`. A root page in a person's Private space has
  `private_owner_uid`; a child page inherits the space of its parent. A deleted
  page stays in the table until its purge starts, and its descendants become
  invisible with it.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset

  alias Ankole.Ecto.ActorRef

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}

  @types ~w(doc database applet file)a

  schema "pages" do
    field :parent_id, Ankole.Ecto.UUIDv7
    field :private_owner_uid, Ankole.Ecto.PrincipalKey
    field :type, Ecto.Enum, values: @types
    field :title, :string, default: ""
    field :role, :string, virtual: true
    field :icon, :string
    field :position, :string
    field :inherit_permissions, :boolean, default: true
    field :revision, :integer, default: 0
    field :saved_from_message_id, Ankole.Ecto.UUIDv7
    field :created_by, ActorRef
    field :deleted_at, :utc_datetime_usec
    field :purge_started_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds the changeset for one page row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(page, attrs) do
    page
    |> cast(
      attrs,
      [
        :id,
        :parent_id,
        :private_owner_uid,
        :type,
        :title,
        :icon,
        :position,
        :inherit_permissions,
        :revision,
        :saved_from_message_id,
        :created_by,
        :deleted_at,
        :purge_started_at,
        :created_at,
        :updated_at
      ],
      empty_values: []
    )
    |> validate_required([:type, :position, :created_by, :created_at, :updated_at])
    |> validate_title()
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_private_owner()
    |> validate_purge_state()
    |> foreign_key_constraint(:parent_id, name: :pages_tenant_id_parent_id_fkey)
    |> unique_constraint(:id, name: :pages_pkey)
    |> check_constraint(:type, name: :pages_type_check)
    |> check_constraint(:parent_id, name: :pages_private_owner)
    |> check_constraint(:purge_started_at, name: :pages_purge_state)
  end

  defp validate_private_owner(changeset) do
    if get_field(changeset, :parent_id) && get_field(changeset, :private_owner_uid) do
      add_error(changeset, :private_owner_uid, "belongs to a root page only")
    else
      changeset
    end
  end

  defp validate_title(changeset) do
    if is_nil(get_field(changeset, :title)),
      do: add_error(changeset, :title, "cannot be null"),
      else: changeset
  end

  defp validate_purge_state(changeset) do
    if get_field(changeset, :purge_started_at) && is_nil(get_field(changeset, :deleted_at)) do
      add_error(changeset, :purge_started_at, "requires a deleted page")
    else
      changeset
    end
  end
end
