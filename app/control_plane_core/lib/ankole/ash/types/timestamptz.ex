defmodule Ankole.Ash.Types.Timestamptz do
  @moduledoc "PostgreSQL timestamptz with microsecond precision and no precision modifier."
  use Ash.Type.NewType, subtype_of: :utc_datetime_usec
  use AshJsonApi.Type

  @impl true
  def storage_type(_constraints), do: :timestamptz

  @impl AshJsonApi.Type
  def json_schema(_constraints), do: %OpenApiSpex.Schema{type: :string, format: :"date-time"}

  @impl AshJsonApi.Type
  def json_write_schema(_constraints), do: %{"type" => "string", "format" => "date-time"}
end
