defmodule Ankole.Tenants.Tenant.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Tenants.Tenant`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:ensure_scaffold, input, _context) do
    Ankole.Errors.wrap(Ankole.Tenants.ensure_scaffold_in_tx(Ankole.Repo, input.arguments.tenant))
  end

  defp action(:create, input, _context) do
    Ankole.Repo
    |> Ankole.Tenants.create_in_tx(input.arguments)
    |> Ankole.Errors.wrap(&Ankole.Tenants.rejection/1)
  end

  defp action(:brain_packs, _input, _context),
    do: {:ok, Ankole.Brain.SchemaPacks.industry_packs()}

  defp action(:change_profile, input, _context) do
    {id, attrs} = Map.pop!(input.arguments, :id)

    Ankole.Repo
    |> Ankole.Tenants.change_profile_in_tx(id, attrs)
    |> Ankole.Errors.wrap(&Ankole.Tenants.rejection/1)
  end

  defp action(:suspend, input, _context) do
    Ankole.Errors.wrap(
      Ankole.Tenants.suspend_in_tx(Ankole.Repo, input.arguments.id),
      &Ankole.Tenants.rejection/1
    )
  end

  defp action(:resume, input, _context) do
    Ankole.Errors.wrap(
      Ankole.Tenants.resume_in_tx(Ankole.Repo, input.arguments.id),
      &Ankole.Tenants.rejection/1
    )
  end

  defp action(:begin_delete, input, _context) do
    Ankole.Errors.wrap(
      Ankole.Tenants.begin_delete_in_tx(Ankole.Repo, input.arguments.id),
      &Ankole.Tenants.rejection/1
    )
  end

  defp action(:transfer_site_administration, input, _context) do
    Ankole.Repo
    |> Ankole.Tenants.transfer_site_administration_in_tx(
      input.arguments.tenant_id,
      input.arguments.site_admin_uid
    )
    |> Ankole.Errors.wrap(&Ankole.Tenants.rejection/1)
  end
end
