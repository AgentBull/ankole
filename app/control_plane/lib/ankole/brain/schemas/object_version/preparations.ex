defmodule Ankole.Brain.Schemas.ObjectVersion.Preparations do
  @moduledoc """
  Runs the preparations of `Ankole.Brain.Schemas.ObjectVersion` that call
  domain code.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, context), do: action(query.action.name, query, context)

  defp action(:console_list, query, context),
    do: Ankole.Brain.Objects.console_versions(query, context)
end
