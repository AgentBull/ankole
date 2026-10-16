defmodule Ankole.Tenants.Tenant do
  @moduledoc """
  One organization's durable data boundary within a site.
  """

  use Ankole.Schema, tenancy: :site
  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tenants" do
    field :slug, :string
    field :display_name, :string
    field :suspended_at, :utc_datetime_usec
    field :deleting_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :display_name])
    |> validate_required([:slug, :display_name])
    |> validate_format(:slug, ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/)
    |> unique_constraint(:slug, name: :tenants_slug_index)
    |> check_constraint(:slug, name: :tenants_slug_format)
    |> check_constraint(:slug, name: :tenants_slug_reserved, message: "is reserved")
    |> check_constraint(:display_name, name: :tenants_display_name_present)
  end
end
