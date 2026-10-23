defmodule Ankole.AIGateway.Schemas.Message.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIGateway.Schemas.Message`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIGateway.{ResponseCommit, StatefulResponses}

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:renew_lease, input, _context),
    do: input.arguments |> ResponseCommit.renew_lease() |> Ankole.Errors.wrap()

  defp action(:fail_generating, input, _context),
    do: input.arguments |> ResponseCommit.fail_generating() |> Ankole.Errors.wrap()

  defp action(:reconcile_orphan, input, _context),
    do: input.arguments |> ResponseCommit.reconcile_orphan() |> Ankole.Errors.wrap()

  defp action(:commit_terminal, input, _context),
    do: input.arguments |> ResponseCommit.commit_terminal_locked() |> Ankole.Errors.wrap()

  defp action(:admit_run, input, _context),
    do: input.arguments |> StatefulResponses.admit_run() |> Ankole.Errors.wrap()

  defp action(:install_recovery_checkpoint, input, _context),
    do: input.arguments |> StatefulResponses.install_recovery_checkpoint() |> Ankole.Errors.wrap()
end
