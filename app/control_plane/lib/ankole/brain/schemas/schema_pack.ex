defmodule Ankole.Brain.Schemas.SchemaPack do
  @moduledoc """
  Installation record of one schema pack.
  """

  use Ecto.Schema

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "brain_schema_packs" do
    field :name, :string
    field :version, :string
    field :content_hash, :string
    field :manifest, :map
    field :installed_at, :utc_datetime_usec
  end
end
