defmodule Ankole.AIGateway.ProviderConfigs.Provider.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIGateway.ProviderConfigs.Provider`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIGateway.ProviderConfigs

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:change, input, _context),
    do: input.arguments |> ProviderConfigs.change_locked() |> Ankole.Errors.wrap()

  defp action(:put, input, _context) do
    input.arguments
    |> ProviderConfigs.put()
    |> Ankole.Errors.wrap(&ProviderConfigs.rejection/1)
  end

  defp action(:enable_provider, input, _context) do
    input.arguments
    |> Map.merge(%{update: :enable, params: %{}})
    |> ProviderConfigs.change_locked()
    |> Ankole.Errors.wrap(&ProviderConfigs.rejection/1)
  end

  defp action(:retire, input, _context) do
    input.arguments
    |> ProviderConfigs.retire()
    |> Ankole.Errors.wrap(&ProviderConfigs.rejection/1)
  end

  defp action(:put_cooldown, input, _context),
    do: input.arguments |> ProviderConfigs.put_cooldown() |> Ankole.Errors.wrap()

  defp action(:rotate_credential, input, _context),
    do: input.arguments |> ProviderConfigs.rotate_credential() |> Ankole.Errors.wrap()
end
