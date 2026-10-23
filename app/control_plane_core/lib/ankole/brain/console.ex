defmodule Ankole.Brain.Console do
  @moduledoc """
  The Console contract of the Brain actions that the Console API runs: the
  operator of a write and the declared error of a failure.

  `AnkoleWeb.JSONAPI.Policy` gives the Principal of the Console session as the
  Ash actor. A Console action records it as the author or the reviewer of its
  write. The actor does not authorize: Principal/AuthZ checks the route first.
  """

  # The domain reasons that conflict with the current state of the target.
  # The v1 Console answered them with 409; the v2 API gives a Conflict.
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
  Makes the result of a generic action of `resource` use the declared errors:
  a missing target is `Ankole.Errors.Invalid.NotFound`, a conflict with the
  current state is `Ankole.Errors.Invalid.Conflict`, and another domain reason
  is a rejection.
  """
  def result(result, resource) do
    result
    |> Ankole.Errors.not_found([:not_found], resource)
    |> Ankole.Errors.wrap(&describe/1)
  end

  defp describe(reason) when reason in @conflicts, do: {:conflict, nil, []}
  defp describe({reason, _value}) when reason in @conflicts, do: {:conflict, nil, []}
  defp describe(_reason), do: nil
end
