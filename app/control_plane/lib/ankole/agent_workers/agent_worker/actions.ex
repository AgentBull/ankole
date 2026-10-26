defmodule Ankole.AgentWorkers.AgentWorker.Actions do
  @moduledoc """
  Runs the JSON:API generic actions of `Ankole.AgentWorkers.AgentWorker`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AgentWorkers.Providers

  @impl true
  def run(%{action: %{name: :console_assign_provider}, arguments: arguments}, _opts, _context),
    do: Providers.console_assign_in_tx(arguments.agent_uid, arguments.provider_id)
end
