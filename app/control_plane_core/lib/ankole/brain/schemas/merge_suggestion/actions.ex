defmodule Ankole.Brain.Schemas.MergeSuggestion.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.MergeSuggestion`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.MergeSuggestion

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:approve_merge, %{arguments: args}, _context) do
    args.suggestion_id
    |> Ankole.Brain.Merge.approve_in_tx(args.decided_by, args.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_approve, %{arguments: args}, context) do
    decided_by = Ankole.Brain.Console.actor_ref(context)
    attrs = %{canonical_slug: args[:canonical_slug]}

    with {:ok, _outcome} <-
           Ankole.Brain.Console.result(
             Ankole.Brain.Merge.approve_in_tx(args.suggestion_id, decided_by, attrs),
             MergeSuggestion
           ),
         do: :ok
  end

  defp action(:console_reject, %{arguments: args}, context) do
    args.suggestion_id
    |> Ankole.Brain.Merge.reject_in_tx(Ankole.Brain.Console.actor_ref(context))
    |> Ankole.Brain.Console.result(MergeSuggestion)
  end

  defp action(:reject_merge, %{arguments: args}, _context) do
    args.suggestion_id
    |> Ankole.Brain.Merge.reject_in_tx(args.decided_by)
    |> Ankole.Errors.wrap()
  end
end
