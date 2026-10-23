defmodule Ankole.Ash.Types.PrincipalKey do
  @moduledoc "Uses the Principal owner's canonical UID codec."
  use Ash.Type
  use AshJsonApi.Type

  @impl true
  def storage_type(_constraints), do: :string

  @impl true
  def ecto_type, do: Ankole.Ecto.PrincipalKey

  @impl true
  def cast_input(value, _constraints), do: Ankole.Ecto.PrincipalKey.cast(value)

  @impl true
  def cast_stored(value, _constraints), do: Ankole.Ecto.PrincipalKey.load(value)

  @impl true
  def dump_to_native(value, _constraints), do: Ankole.Ecto.PrincipalKey.dump(value)

  @impl AshJsonApi.Type
  def json_schema(_constraints), do: %OpenApiSpex.Schema{type: :string}
end
