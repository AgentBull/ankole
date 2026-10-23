defmodule Ankole.AppConfigure.AppConfig.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AppConfigure.AppConfig`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:update_tenant, input, _context) do
    Ankole.Repo
    |> Ankole.AppConfigure.update_tenant_in_tx(
      input.arguments.definition,
      input.arguments.updater
    )
    |> Ankole.Errors.wrap()
  end
end
