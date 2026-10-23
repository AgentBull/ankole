defmodule Ankole.Brain.Schemas.Claim.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Claim`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.Claim

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:write_fact, %{arguments: args}, _context) do
    args.attrs
    |> Ankole.Brain.Claims.record_fact_in_tx(args.writer, args.embedding, args.options)
    |> Ankole.Errors.wrap()
  end

  defp action(:supersede_claim, %{arguments: args}, _context) do
    args.claim_id
    |> Ankole.Brain.Claims.supersede_claim_in_tx(args.attrs, args.writer,
      author: args[:author],
      embedding: args.embedding
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:expire_fact_by_id, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.Brain.Claims.expire_fact_in_tx(args.claim_id))

  defp action(:deactivate_take_by_id, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.Brain.Claims.deactivate_take_in_tx(args.claim_id))

  defp action(:resolve_take_by_id, %{arguments: args}, _context) do
    args.claim_id
    |> Ankole.Brain.Claims.resolve_take_in_tx(args.resolution, args.resolved_by)
    |> Ankole.Errors.wrap()
  end

  defp action(:attach_claim_embedding, %{arguments: args}, _context) do
    args.claim
    |> Ankole.Brain.Claims.attach_embedding_in_tx(
      args.embedding,
      args.signature,
      args[:now] || DateTime.utc_now(:microsecond)
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:commit_grade, %{arguments: args}, _context) do
    args.take_id
    |> Ankole.Brain.Calibration.commit_grade_in_tx(args.input_hash, args.output)
    |> Ankole.Errors.wrap()
  end

  defp action(:forget_claim, %{arguments: args}, _context) do
    args.claim_id
    |> Ankole.Brain.Forget.forget_claim_in_tx(args.reason, args.caller)
    |> Ankole.Errors.wrap()
  end

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

  defp action(:consolidate_facts, %{arguments: args}, _context) do
    args.take
    |> Ankole.Brain.Claims.consolidate_facts_in_tx(args.fact_ids, args[:embedding])
    |> Ankole.Errors.wrap()
  end
end
