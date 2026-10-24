defmodule Ankole.AuthZ.Checks.ActorGuardrail do
  @moduledoc false
  @behaviour Ankole.AuthZ.Check
  alias Ankole.AuthZ.Actor

  def check(
        %Actor{principal: %{status: :active, tenant_id: tenant, membership: membership}} = actor,
        scope
      ) do
    with true <- scope == :site_console or tenant == Ankole.Repo.tenant_id(),
         true <- membership != :guest or Ankole.Pod.Config.allow_external_guests?(),
         :ok <- interactive(actor, scope),
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  def check(_, _), do: {:error, :forbidden}
  defp interactive(%Actor{interactive_principal: nil}, _), do: :ok
  defp interactive(actor, scope), do: check(Actor.interactive(actor), scope)
end
