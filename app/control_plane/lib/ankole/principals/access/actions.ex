defmodule Ankole.Principals.Access.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Ankole.Principals
  alias Ankole.Principals.HumanAccess
  alias Ankole.Principals.WorkAccess
  alias Ankole.Principals.WorkCleanup

  @impl true
  def run(input, _opts, context) do
    action(input.action.name, input.arguments, context)
    |> Ankole.Errors.not_found([:not_found], Principals.Principal)
    |> Ankole.Errors.wrap(&describe/1)
  end

  defp action(:show, args, _context), do: HumanAccess.console_view(args.uid)
  defp action(:unresolved_work, _args, _context), do: {:ok, %{work: WorkAccess.list_unresolved()}}

  defp action(:disable, args, context) do
    HumanAccess.disable(
      args.uid,
      args.reason,
      actor(context),
      args.operation_id,
      args.disposition
    )
    |> changed(args.uid)
  end

  defp action(:clear_restriction, args, context) do
    HumanAccess.clear_restriction(
      args.uid,
      args.restriction_id,
      actor(context),
      args.reason,
      args.operation_id
    )
    |> changed(args.uid)
  end

  defp action(:restore, args, context) do
    HumanAccess.restore(args.uid, actor(context), args.reason, args.operation_id)
    |> changed(args.uid)
  end

  defp action(:retry_cleanup, args, _context) do
    with {:ok, %{type: :human} = principal} <- Principals.get_principal(args.uid),
         :ok <- WorkCleanup.enqueue_in_tx(args.uid, principal.access_version) do
      HumanAccess.console_view(args.uid)
    else
      {:ok, _} -> {:error, :not_human}
      error -> error
    end
  end

  defp action(:classify_work, args, context) do
    human_uid = if args.authorization_kind == :human, do: Map.get(args, :human_uid)

    with true <- args.authorization_kind == :service or (is_binary(human_uid) and human_uid != ""),
         {:ok, _} <-
           WorkAccess.classify(args.kind, args.id, human_uid, actor(context), args.reason) do
      {:ok, %{work: WorkAccess.list_unresolved()}}
    else
      false -> {:error, :human_uid_required}
      error -> error
    end
  end

  defp actor(context), do: Ankole.ActorRef.from_actor(context.actor)
  defp changed({:ok, _}, uid), do: HumanAccess.console_view(uid)
  defp changed(error, _uid), do: error

  defp describe(:not_human), do: {"This operation applies to Human users only.", []}

  defp describe(:last_active_human_admin),
    do: Ankole.AuthZ.describe_group_refusal(:last_active_human_admin)

  defp describe(:cannot_disable_self), do: {:conflict, "You cannot disable your own access.", []}

  defp describe(:provider_recovery_not_verified),
    do:
      {:conflict, "Verify recovery with the identity provider before clearing this restriction.",
       []}

  defp describe(:tenant_deleting),
    do: {:conflict, "Access cannot be restored while the tenant is being deleted.", []}

  defp describe(:human_uid_required), do: {"Select the Human who authorizes this work.", []}

  defp describe(:invalid_work_review),
    do: {"Select valid work and give a reason for its authority.", []}

  defp describe(:work_review_changed),
    do: {:conflict, "This work changed. Read the current work review and try again.", []}

  defp describe(reason) when is_atom(reason),
    do: {:conflict, "Review the current access state and try again.", []}

  defp describe(_), do: nil
end
