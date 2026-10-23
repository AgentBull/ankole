defmodule Ankole.AgentWorkers.AgentWorker.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AgentWorkers.AgentWorker`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.WorkerAdmission
  alias Ankole.AgentWorkers.WorkerRouteAuth
  alias Ankole.Errors

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:admit_connection, input, _context),
    do: Errors.wrap(WorkerAdmission.admit_in_tx(input.arguments))

  defp action(:renew_connection, input, _context),
    do: Errors.wrap(WorkerAdmission.renew_in_tx(input.arguments))

  defp action(:drain_connection, input, _context),
    do: Errors.wrap(WorkerAdmission.drain_in_tx(input.arguments))

  defp action(:release_route, input, _context),
    do: Errors.wrap(WorkerAdmission.release_route_in_tx(input.arguments))

  defp action(:expire_connection, input, _context),
    do: Errors.wrap(WorkerAdmission.expire_in_tx(input.arguments))

  defp action(:assign_provider_once, %{arguments: arguments}, _context) do
    Errors.wrap(Providers.assign_in_tx(Ankole.Repo, arguments.agent_uid, arguments.provider_id))
  end

  defp action(:console_assign_provider, %{arguments: arguments}, _context),
    do: Providers.console_assign_in_tx(arguments.agent_uid, arguments.provider_id)

  defp action(:decide_reconcile_step, input, _context),
    do: Errors.wrap(ReconcileJob.decide_in_tx(input.arguments))

  defp action(:record_reconcile_result, input, _context),
    do: Errors.wrap(ReconcileJob.record_in_tx(input.arguments))

  defp action(:record_prepare_error, input, _context),
    do: Errors.wrap(ReconcileJob.record_prepare_error_in_tx(input.arguments))

  defp action(:authorize_turn, %{arguments: arguments}, _context) do
    WorkerRouteAuth.authorize_turn_in_tx(
      Ankole.Repo,
      arguments.ref,
      arguments.agent_uid,
      arguments.effect
    )
    |> case do
      {:ok, :authorized} -> :ok
      error -> Errors.wrap(error)
    end
  end
end
