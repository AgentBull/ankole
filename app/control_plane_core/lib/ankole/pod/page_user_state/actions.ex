defmodule Ankole.Pod.PageUserState.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Pod.PageUserState`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:save, %{arguments: a}, _context) do
    Ankole.Errors.wrap(Ankole.Pod.Pages.save_state_in_tx(a.principal_uid, a.page_id, a.changes))
  end
end
