defmodule Ankole.Brain.Schemas.Claim.Preparations do
  @moduledoc """
  Runs the preparations of `Ankole.Brain.Schemas.Claim` that call domain code.

  A claim text gets its embedding from the network before the transaction.
  """
  use Ash.Resource.Preparation

  alias Ankole.Brain.Claims

  @impl true
  def supports(_opts), do: [Ash.Query, Ash.ActionInput]

  @impl true
  def prepare(subject, _opts, context), do: action(subject.action.name, subject, context)

  defp action(:console_list, query, context), do: Claims.console_list(query, context)

  defp action(:write_fact, input, _context),
    do: Ash.ActionInput.before_transaction(input, &Claims.prepare_fact_input/1)

  defp action(:supersede_claim, input, _context),
    do: Ash.ActionInput.before_transaction(input, &Claims.prepare_replacement_input/1)

  defp action(:expire_fact_by_id, input, _context) do
    Ash.ActionInput.before_transaction(input, fn input ->
      Ash.ActionInput.set_private_argument(
        input,
        :embedding,
        Claims.prepare_embedding(input.arguments.claim)
      )
    end)
  end
end
