defmodule Ankole.Ash.Types.JSONValue do
  @moduledoc "Uses the shared JSON value contract for Ash attributes."
  use Ash.Type
  @impl true
  def storage_type(_), do: :map
  @impl true
  def ecto_type, do: Ankole.Types.JSONValue
  @impl true
  def cast_input(value, _), do: Ankole.Types.JSONValue.cast(value)
  @impl true
  def cast_stored(value, _), do: Ankole.Types.JSONValue.load(value)
  @impl true
  def dump_to_native(value, _), do: Ankole.Types.JSONValue.dump(value)
end
