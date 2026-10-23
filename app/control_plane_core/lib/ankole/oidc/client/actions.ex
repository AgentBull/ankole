defmodule Ankole.OIDC.Client.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.Client`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:login_sources, _input, _context) do
    with {:ok, providers} <- Ankole.IdentityProviders.list_configured_providers() do
      sources =
        Enum.map(providers, &Map.take(&1, ["provider_id", "enabled"])) ++
          Enum.map(
            Ankole.IdentityProviders.SiteSources.providers(),
            &%{"provider_id" => &1["provider_id"], "enabled" => true}
          )

      {:ok, %{sources: sources}}
    end
  end

  defp action(:console_rotate_secret, input, _context) do
    case Ankole.OIDC.rotate_secret(input.arguments.id) do
      {:ok, result} -> {:ok, %{client_secret: result.client_secret}}
      error -> error
    end
    |> Ankole.Errors.not_found([:not_found], Ankole.OIDC.Client)
    |> Ankole.Errors.wrap(fn
      :public_client -> {:conflict, "Public clients do not have a secret.", []}
      _ -> nil
    end)
  end

  defp action(:console_create, input, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.console_create_in_tx(input.arguments))

  defp action(:console_update, input, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.console_update_in_tx(input.arguments))

  defp action(:console_delete, input, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.console_delete_in_tx(input.arguments.id))

  defp action(:create_client, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.create_client_in_tx(args.attrs, args.group_ids))

  defp action(:update_client, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.update_client_in_tx(args.id, args.attrs))
end
