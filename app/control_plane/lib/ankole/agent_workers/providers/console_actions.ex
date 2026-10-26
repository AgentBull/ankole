defmodule Ankole.AgentWorkers.Providers.ConsoleActions do
  @moduledoc "Calls the provider catalog and the real provider connection check."
  use Ash.Resource.Actions.Implementation
  alias Ankole.AgentWorkers.Providers
  alias Ankole.Errors
  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_kinds, _input, _context) do
    items =
      Enum.map(
        Ankole.AgentWorkers.ProviderKind.all(),
        &Map.take(&1.definition(), [:kind, :example, :credentials])
      )

    {:ok, %{worker_provider_kinds: items}}
  end

  defp action(:console_check, input, _context) do
    result =
      with :ok <- Providers.check(input.arguments.provider_id), do: {:ok, %{available: true}}

    Errors.wrap(result, &Providers.Errors.rejection/1)
  end
end
