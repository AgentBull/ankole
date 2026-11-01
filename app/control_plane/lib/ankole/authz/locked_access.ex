defmodule Ankole.AuthZ.LockedAccess do
  @moduledoc "Checks a locked Pod record within the transaction that owns the operation."
  def authorize_in_tx(%Ankole.AuthZ.Actor{} = actor, record, action, opts \\ []) do
    with :ok <- Ankole.Repo.require_transaction(),
         :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :pod),
         do: Ankole.Files.Access.authorize(actor, record, action, opts)
  end
end
