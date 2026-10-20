defmodule Ankole.TestModules do
  @moduledoc false

  def all do
    Application.loaded_applications()
    |> Enum.flat_map(fn {app, _description, _version} ->
      Application.spec(app, :modules) || []
    end)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Ankole"))
    |> Enum.uniq()
  end
end
