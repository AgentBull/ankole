defmodule Ankole.AIGateway.ProviderConfigs.Provider.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIGateway.ProviderConfigs.Provider`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIGateway.ProviderConfigs

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_add_credential, %{arguments: args}, _context),
    do: credential_change(args, :add_credential, %{input: args.credential})

  defp action(:console_put_credential, %{arguments: args}, _context),
    do:
      credential_change(args, :replace_credential, %{
        input: args.credential,
        credential_id: args.credential_id
      })

  defp action(:console_delete_credential, %{arguments: args}, _context),
    do: credential_change(args, :remove_credential, %{credential_id: args.credential_id})

  defp action(:console_credential_strategy, %{arguments: args}, _context),
    do: credential_change(args, :select_strategy, %{strategy: args.strategy})

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

  defp credential_change(args, update, params) do
    %{provider_id: args.provider_id, update: update, params: params}
    |> ProviderConfigs.change_locked()
    |> Ankole.Errors.wrap(&ProviderConfigs.rejection/1)
  end
end
