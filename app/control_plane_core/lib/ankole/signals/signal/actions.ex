defmodule Ankole.Signals.Signal.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Signals.Signal`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:intake, input, _context),
    do: Ankole.Errors.wrap(Ankole.Signals.Intake.accept(Ankole.Repo, input.arguments.attrs))

  defp action(:intake_all, input, _context) do
    Ankole.Repo
    |> Ankole.Signals.Intake.accept_all(input.arguments.attrs_list)
    |> Ankole.Errors.wrap()
  end
end
