defmodule Ankole.Principals.Agent.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Principals.Agent`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Principals.AgentConsole

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_rename, input, _context) do
    Ankole.Principals.Rename.from_console(:agent, input.arguments)
    |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
  end

  defp action(:console_create, input, context) do
    input.arguments
    |> AgentConsole.create_in_tx(context.actor.principal)
    |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
  end

  defp action(:console_update, input, _context) do
    input.arguments
    |> AgentConsole.update_in_tx()
    |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
  end

  defp action(:console_enable, input, _context) do
    input.arguments.uid
    |> AgentConsole.enable_in_tx()
    |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
  end

  defp action(:console_delete, input, _context) do
    input.arguments.uid
    |> AgentConsole.delete_in_tx()
    |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
  end
end
