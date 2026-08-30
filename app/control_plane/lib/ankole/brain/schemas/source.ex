defmodule Ankole.Brain.Schemas.Source do
  @moduledoc """
  One upstream source this instance can learn from. A Source registers where
  the organization learns; it is not a permission boundary and not an object
  namespace. Archiving stops later synchronization. For a Library Source, it
  also withdraws that Source's product-managed page projections.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "brain_sources" do
    field :upstream_id, :string
    field :kind, :string
    field :name, :string
    field :default_audience_scope, :string
    field :config, :map, default: %{}
    field :upstream_revision, :string
    field :last_sync_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: :updated_at)
  end

  @doc false
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :upstream_id,
      :kind,
      :name,
      :default_audience_scope,
      :config,
      :upstream_revision,
      :last_sync_at,
      :archived_at
    ])
    |> validate_required([:upstream_id, :kind, :name])
    |> unique_constraint([:kind, :upstream_id], name: :brain_sources_kind_upstream_key)
    |> check_constraint(:upstream_id, name: :brain_sources_upstream_present)
    |> check_constraint(:kind, name: :brain_sources_kind_present)
    |> check_constraint(:name, name: :brain_sources_name_present)
    |> check_constraint(:default_audience_scope, name: :brain_sources_default_scope_format)
    |> check_constraint(:config, name: :brain_sources_config_object)
  end
end
