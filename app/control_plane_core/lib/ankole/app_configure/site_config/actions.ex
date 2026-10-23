defmodule Ankole.AppConfigure.SiteConfig.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AppConfigure.SiteConfig`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:ensure_generated_global, input, _context) do
    Ankole.AppConfigure.ensure_generated_global_in_tx(Ankole.Repo, input.arguments.definition)
    |> Ankole.Errors.wrap()
  end

  defp action(:update_global, input, _context) do
    Ankole.Repo
    |> Ankole.AppConfigure.update_global_in_tx(
      input.arguments.definition,
      input.arguments.updater
    )
    |> Ankole.Errors.wrap()
  end
end
