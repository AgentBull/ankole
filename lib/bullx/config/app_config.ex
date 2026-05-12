defmodule BullX.Config.AppConfig do
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "app_configs" do
    field :value, :string
    field :type, Ecto.Enum, values: [:plain, :secret], default: :plain
    timestamps(type: :utc_datetime)
  end
end
