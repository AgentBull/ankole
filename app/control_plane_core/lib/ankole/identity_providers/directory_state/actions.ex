defmodule Ankole.IdentityProviders.DirectoryState.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.IdentityProviders.DirectoryState`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:save_configuration, input, _context) do
    Ankole.IdentityProviders.Config.save_provider_in_tx(
      Ankole.Repo,
      input.arguments.activation,
      input.arguments.config,
      input.arguments.application
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:upsert_user, input, _context) do
    Ankole.IdentityProviders.Directory.upsert_user_in_tx(
      Ankole.Repo,
      input.arguments.provider_id,
      input.arguments.attrs,
      input.arguments.opts
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:begin_sync, input, _context) do
    Ankole.IdentityProviders.DirectoryAccess.begin_sync_in_tx(
      Ankole.Repo,
      input.arguments.provider_id,
      input.arguments.expected_config
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:finish_sync, input, _context) do
    Ankole.IdentityProviders.DirectoryAccess.finish_sync_in_tx(
      Ankole.Repo,
      input.arguments.ticket,
      input.arguments.scope,
      input.arguments.observations,
      input.arguments.opts
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:approve_snapshot, input, _context) do
    Ankole.IdentityProviders.DirectoryAccess.approve_snapshot_in_tx(
      Ankole.Repo,
      input.arguments.provider_id,
      input.arguments.fingerprint,
      input.arguments.actor,
      input.arguments.reason,
      input.arguments.confirm_removals
    )
    |> Ankole.Errors.wrap()
  end
end
