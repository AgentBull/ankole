defmodule Ankole.Workflow.Schemas.Run.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Workflow.Schemas.Run`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_with_dispatch, input, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Lifecycle.create_with_dispatch_in_tx(input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:replay_input, input, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Replay.replay_input_in_tx(input.arguments.run_id)
    |> Ankole.Errors.wrap()
  end

  defp action(:commit_replay_pending, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Replay.commit_replay_pending_in_tx(
      args.run_id,
      args.pending_calls,
      args.expected_memo_length
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:complete_replay, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Replay.complete_replay_in_tx(
      args.run_id,
      args.result_text,
      args.expected_memo_length
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:fail_replay, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Replay.fail_replay_in_tx(
      args.run_id,
      args.code,
      args.summary,
      args.expected_memo_length
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:reconcile_stale_tasks, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Recovery.reconcile_stale_tasks_in_tx(
      args.run_id,
      args.cutoff,
      args.reconciled_at
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:complete_cleanup, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Workflow.Lifecycle.complete_cleanup_in_tx(args.run_id, args.completed_at)
    |> Ankole.Errors.wrap()
  end
end
