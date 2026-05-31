defmodule BullX.Config.AppConfig do
  @moduledoc """
  Database row for runtime application configuration.

  BullX keeps operator-entered setup values in PostgreSQL so the committed
  runtime shape survives process restarts. `:plain` values are stored as-is;
  `:secret` values are encrypted before reaching this schema and decrypted
  only into the in-memory config cache.
  """

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "app_configs" do
    field :value, :string
    field :type, Ecto.Enum, values: [:plain, :secret], default: :plain
    timestamps(type: :utc_datetime)
  end
end
