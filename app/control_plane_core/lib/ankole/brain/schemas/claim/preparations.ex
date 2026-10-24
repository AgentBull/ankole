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

  defp action(:console_supersede, input, _context) do
    Ash.ActionInput.before_transaction(input, fn input ->
      Ash.ActionInput.set_private_argument(
        input,
        :embedding,
        Claims.prepare_embedding(input.arguments.claim)
      )
    end)
  end
end
