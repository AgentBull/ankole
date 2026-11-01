defmodule Ankole.Signals.Binding.Actions do
  @moduledoc """
  Runs `:console_disable` on `Ankole.Signals.Binding`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Signals.{Binding, Bindings}

  @impl true
  def run(%{arguments: args}, _opts, _context) do
    Bindings.disable_binding_in_tx(args.id)
    |> Ankole.Errors.not_found([:agent_not_found, :binding_not_found], Binding)
    |> Ankole.Errors.wrap()
  end
end
