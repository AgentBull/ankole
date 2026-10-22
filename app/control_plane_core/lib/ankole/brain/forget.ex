defmodule Ankole.Brain.Forget do
  @moduledoc """
  Deliberate forgetting: facts expire, takes deactivate, objects soft-delete.

  Every forget carries a reason that lands in the target's provenance trail.
  Eligibility: a Principal that satisfies the target's scope, the author,
  or a Console administrator (`:admin` caller). History is never erased
  here; purge hard-deletes only soft-deleted objects past their TTL.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @type caller :: String.t() | :admin

  @doc """
  Forgets one claim: a fact expires, a take deactivates. The reason appends
  to the row's provenance.
  """
  @spec forget_claim(Ecto.UUID.t(), String.t(), caller()) :: {:ok, Claim.t()} | {:error, term()}
  def forget_claim(claim_id, reason, caller) when is_binary(reason) do
    with :ok <- validate_reason(reason),
         {:ok, claim} <- fetch_claim(claim_id),
         :ok <- validate_eligibility(claim, caller) do
      # State change and reason commit together: a crash between them must
      # not leave a forgotten claim without its required reason.
      Repo.transact(fn _repo ->
        result =
          case claim.claim_type do
            :fact -> Claims.expire_fact_in_tx(claim.id)
            :take -> Claims.deactivate_take_in_tx(claim.id)
          end

        with {:ok, updated} <- result do
          Ankole.Ash.update(updated, :append_forgetting_reason, %{
            reason: forgetting_reason(reason, caller)
          })
        end
      end)
    end
  end

  @doc """
  Soft-deletes one object; it leaves ordinary recall and waits for purge.
  The reason and the caller land in the object's meta until a restore.
  """
  @spec forget_object(String.t(), String.t(), caller()) :: {:ok, map()} | {:error, term()}
  def forget_object(slug, reason, caller) when is_binary(reason) do
    with :ok <- validate_reason(reason),
         {:ok, object} <- Objects.resolve_slug(slug),
         :ok <- validate_object_eligibility(object, caller) do
      Ankole.Ash.run_action(Object, :soft_delete_object, %{
        slug: object.slug,
        reason: String.trim(reason),
        by: caller_label(caller)
      })
    end
  end

  defp validate_reason(reason) do
    if String.trim(reason) == "", do: {:error, :forget_reason_required}, else: :ok
  end

  defp fetch_claim(claim_id) do
    case Repo.get(Claim, claim_id) do
      %Claim{} = claim -> {:ok, claim}
      nil -> {:error, :not_found}
    end
  end

  defp validate_eligibility(_claim, :admin), do: :ok

  defp validate_eligibility(%Claim{} = claim, caller) when is_binary(caller) do
    reference = Ankole.ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: caller})

    if claim.author == reference or Scope.satisfied_by?(claim.audience_scope, caller),
      do: :ok,
      else: {:error, :forget_not_eligible}
  end

  defp validate_object_eligibility(_object, :admin), do: :ok

  # An object has no single scope; eligibility follows the body scopes: the
  # caller must satisfy every scoped segment it wants to remove from recall.
  defp validate_object_eligibility(object, caller) when is_binary(caller) do
    case Ankole.Brain.Markdoc.scopes(object.body) do
      {:ok, scopes} ->
        if Enum.all?(scopes, &Scope.satisfied_by?(&1, caller)),
          do: :ok,
          else: {:error, :forget_not_eligible}

      {:error, _reason} ->
        {:error, :forget_not_eligible}
    end
  end

  defp forgetting_reason(reason, caller) do
    " | forgotten by #{caller_label(caller)}: #{String.trim(reason)}"
  end

  defp caller_label(:admin), do: "console admin"
  defp caller_label(uid) when is_binary(uid), do: uid
end
