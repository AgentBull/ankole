defmodule Ankole.AuthZ.Checks.ActorGuardrail do
  @moduledoc false
  @behaviour Ankole.AuthZ.Check
  alias Ankole.AuthZ.Actor

  def check(
        %Actor{principal: %{status: :active, tenant_id: tenant, membership: membership}},
        scope
      ) do
    with true <- scope == :site_console or tenant == Ankole.Repo.tenant_id(),
         true <-
           membership != :guest or
             Ankole.AppConfigure.get_by_key("pod.allow_external_guests") == {:ok, true},
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  def check(_, _), do: {:error, :forbidden}
end
