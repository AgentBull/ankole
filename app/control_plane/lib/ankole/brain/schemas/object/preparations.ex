defmodule Ankole.Brain.Schemas.Object.Preparations do
  @moduledoc """
  Runs the preparations of `Ankole.Brain.Schemas.Object` that call domain code.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, context), do: action(query.action.name, query, context)

  defp action(:console_list, query, context),
    do: Ankole.Brain.Objects.console_list(query, context)
end
