defmodule Ankole.AgentWorkers.Providers.Provider.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AgentWorkers.Providers.Provider`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Providers.Seed
  alias Ankole.Errors
  alias Ankole.Repo

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:add, input, _context) do
    Errors.wrap(
      Providers.create_in_tx(Repo, input.arguments),
      &Providers.Errors.rejection/1
    )
  end

  defp action(:configure_provider, %{arguments: arguments}, _context) do
    {provider_id, attrs} = Map.pop!(arguments, :provider_id)

    Errors.wrap(
      Providers.configure_in_tx(Repo, provider_id, attrs),
      &Providers.Errors.rejection/1
    )
  end

  defp action(:delete_provider, input, _context) do
    Errors.wrap(
      Providers.delete_in_tx(Repo, input.arguments.provider_id),
      &Providers.Errors.rejection/1
    )
  end

  defp action(:import_seed, input, _context),
    do: Errors.wrap(Seed.import_in_tx(Repo, input.arguments.path))
end
