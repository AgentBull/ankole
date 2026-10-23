defmodule Ankole.Brain.ConsoleOperator do
  @moduledoc """
  Gives the operator of a Brain action that the Console API runs.

  `AnkoleWeb.JSONAPI.Policy` puts the Principal of the Console session in the
  action context under `:principal` after the AuthZ check. A Console action
  records this Principal as the author or the reviewer of its write.
  """

  @doc "Gives the attribution of the operator."
  @spec actor_ref(map()) :: Ankole.ActorRef.t()
  def actor_ref(%{principal: principal}), do: Ankole.ActorRef.from_principal(principal)

  @doc """
  Gives the Brain writer of the operator: the Principal UID in its own
  tenant. A site administrator who works in the data of another tenant is
  not a Principal of that tenant, so it writes as `:system` with its
  attribution as the author.
  """
  @spec writer(map()) :: String.t() | :system
  def writer(%{principal: principal}) do
    if principal.tenant_id == Ankole.Repo.tenant_id!(), do: principal.uid, else: :system
  end
end
