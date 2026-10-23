defmodule Ankole.Brain.Console do
  @moduledoc """
  The Console contract of the Brain actions that the Console API runs: the
  operator of a write and the declared error of a failure.

  `AnkoleWeb.JSONAPI.Policy` gives the Principal of the Console session as the
  Ash actor. A Console action records it as the author or the reviewer of its
  write. The actor does not authorize: Principal/AuthZ checks the route first.
  """

  alias Ankole.Errors.Invalid.NotFound
  alias Ankole.Errors.Invalid.Stale

  # The domain reasons that tell that the target changed or that its state
  # does not permit the write. The Console gives them as conflicts (409).
  @conflicts [:conflict, :content_hash_conflict, :object_deleted, :slug_taken]

  @doc "Gives the attribution of the operator."
  @spec actor_ref(map()) :: Ankole.ActorRef.t()
  def actor_ref(%{actor: principal}), do: Ankole.ActorRef.from_principal(principal)

  @doc """
  Gives the Brain writer of the operator: the Principal UID in its own
  tenant. A site administrator who works in the data of another tenant is
  not a Principal of that tenant, so it writes as `:system` with its
  attribution as the author.
  """
  @spec writer(map()) :: String.t() | :system
  def writer(%{actor: principal}) do
    if principal.tenant_id == Ankole.Repo.tenant_id!(), do: principal.uid, else: :system
  end

  @doc """
  Makes the result of a generic action use the declared errors: a missing
  target is `NotFound`, a conflict is `Stale` with its reason, and another
  domain reason is a rejection (`Ankole.Errors.wrap/1`).
  """
  def result({:error, :not_found}), do: {:error, NotFound.exception([])}

  def result({:error, reason}) when is_atom(reason) and reason in @conflicts,
    do: {:error, Stale.exception(reason: reason)}

  def result({:error, {reason, _value}}) when reason in @conflicts,
    do: {:error, Stale.exception(reason: reason)}

  def result(result), do: Ankole.Errors.wrap(result)
end
