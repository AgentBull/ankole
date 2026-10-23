defmodule Ankole.Brain.Schemas.SchemaSuggestion.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.SchemaSuggestion`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.SchemaSuggestion

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:approve_promotion, %{arguments: args}, _context) do
    args.suggestion_id
    |> Ankole.Brain.Promotion.approve_in_tx(args.decided_by, args.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_approve, %{arguments: args}, context) do
    attrs = Map.take(args, [:primitive, :slug_prefix, :target_type, :extractable])
    decided_by = Ankole.Brain.Console.actor_ref(context)

    with {:ok, _outcome} <-
           Ankole.Brain.Console.result(
             Ankole.Brain.Promotion.approve_in_tx(args.suggestion_id, decided_by, attrs),
             SchemaSuggestion
           ),
         do: :ok
  end

  defp action(:console_reject, %{arguments: args}, context) do
    args.suggestion_id
    |> Ankole.Brain.Promotion.reject_in_tx(Ankole.Brain.Console.actor_ref(context))
    |> Ankole.Brain.Console.result(SchemaSuggestion)
  end

  defp action(:reject_promotion, %{arguments: args}, _context) do
    args.suggestion_id
    |> Ankole.Brain.Promotion.reject_in_tx(args.decided_by)
    |> Ankole.Errors.wrap()
  end
end
