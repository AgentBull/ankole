defmodule Ankole.Brain.Schemas.Claim.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Claim`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.Claim

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_supersede, %{arguments: args}, context) do
    attrs =
      args
      |> Map.take([
        :claim,
        :kind,
        :confidence,
        :weight,
        :notability,
        :audience_scope,
        :provenance
      ])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    args.claim_id
    |> Ankole.Brain.Claims.supersede_claim_in_tx(
      attrs,
      Ankole.Brain.Console.writer(context),
      author: Ankole.Brain.Console.actor_ref(context),
      embedding: args.embedding
    )
    |> Ankole.Brain.Console.result(Claim)
  end

  defp action(:console_forget, %{arguments: args}, _context) do
    args.claim_id
    |> Ankole.Brain.Forget.forget_claim_in_tx(args[:reason] || "", :admin)
    |> Ankole.Brain.Console.result(Claim)
  end

  defp action(:console_resolve, %{arguments: args}, context) do
    resolution =
      Map.take(args, [
        :resolved_quality,
        :resolved_outcome,
        :resolved_value,
        :resolved_unit,
        :resolution_provenance
      ])

    resolved_by = to_string(Ankole.Brain.Console.actor_ref(context))

    args.claim_id
    |> Ankole.Brain.Claims.resolve_take_in_tx(resolution, resolved_by)
    |> Ankole.Brain.Console.result(Claim)
  end
end
