defmodule Ankole.Brain.Claims.Dedup do
  @moduledoc """
  Semantic and deterministic Base-record deduplication for Brain Facts.

  Candidates are scoped to the same `source_node_id` and `subject_page_id`,
  then re-read under a row lock so concurrent Fact writes never supersede a
  row that already left the current state.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Repo

  @dedup_threshold 0.95
  @dedup_candidate_limit 5
  @dedup_attempts 5

  def resolve_in_tx(attrs, embedding_tuple, lock_claim_fn, attempts \\ @dedup_attempts)

  def resolve_in_tx(_attrs, _embedding_tuple, _lock_claim_fn, 0),
    do: {:error, :dedup_target_contended}

  def resolve_in_tx(attrs, embedding_tuple, lock_claim_fn, attempts) do
    case find_candidate(attrs, embedding_tuple) do
      :insert ->
        :insert

      {action, candidate_id} ->
        case lock_claim_fn.(candidate_id) do
          {:ok, %Claim{claim_type: :fact, expired_at: nil, superseded_by: nil} = target} ->
            {action, target}

          _replaced_or_removed ->
            resolve_in_tx(attrs, embedding_tuple, lock_claim_fn, attempts - 1)
        end
    end
  end

  defp find_candidate(_attrs, nil), do: :insert

  defp find_candidate(attrs, {embedding, signature})
       when is_nil(embedding) or is_nil(signature) do
    find_deterministic_candidate(attrs)
  end

  defp find_candidate(attrs, {embedding, signature}) do
    candidates =
      attrs
      |> candidates_query()
      |> where([claim], not is_nil(claim.embedding) and claim.embedding_signature == ^signature)
      |> order_by([claim], fragment("? <=> ?", claim.embedding, ^embedding))
      |> limit(@dedup_candidate_limit)
      |> select([claim], %{
        id: claim.id,
        claim: claim.claim,
        kind: claim.kind,
        similarity: fragment("1 - (? <=> ?)", claim.embedding, ^embedding)
      })
      |> Repo.all()

    case candidates do
      [%{similarity: similarity} = top | _rest] when similarity >= @dedup_threshold ->
        if normalized_text(top.claim) != normalized_text(attrs[:claim]) and
             top.kind == attrs[:kind],
           do: {:supersede, top.id},
           else: {:duplicate, top.id}

      _no_vector_hit ->
        if extract_record_tag(attrs[:provenance]),
          do: find_record_tag_candidate(attrs),
          else: :insert
    end
  end

  defp find_deterministic_candidate(attrs) do
    target_text = normalized_text(attrs[:claim] || "")

    candidates =
      attrs
      |> candidates_query()
      |> order_by([claim], desc: claim.created_at, desc: claim.id)
      |> limit(50)
      |> select([claim], %{id: claim.id, claim: claim.claim})
      |> Repo.all()

    case Enum.find(candidates, &(normalized_text(&1.claim) == target_text)) do
      %{id: id} -> {:duplicate, id}
      nil -> find_record_tag_candidate(attrs)
    end
  end

  defp find_record_tag_candidate(attrs) do
    case extract_record_tag(attrs[:provenance]) do
      nil ->
        :insert

      record_tag ->
        pattern = "%" <> Repo.escape_like(record_tag) <> "%"
        target_text = normalized_text(attrs[:claim] || "")

        prior =
          attrs
          |> candidates_query()
          |> where([claim], claim.kind == ^attrs[:kind] and ilike(claim.provenance, ^pattern))
          |> order_by([claim], desc: claim.created_at, desc: claim.id)
          |> limit(1)
          |> select([claim], %{id: claim.id, claim: claim.claim})
          |> Repo.one()

        case prior do
          nil ->
            :insert

          %{id: id, claim: text} ->
            if normalized_text(text) == target_text, do: {:duplicate, id}, else: {:supersede, id}
        end
    end
  end

  defp candidates_query(attrs) do
    base =
      Claim
      |> Claims.current_external_facts()
      |> where([claim], claim.source_node_id == ^attrs[:source_node_id])
      |> where(
        [claim],
        fragment(
          "? IS NOT DISTINCT FROM ?",
          claim.subject_page_id,
          type(^attrs[:subject_page_id], Ecto.UUID)
        )
      )

    case attrs[:exclude_id] do
      nil -> base
      exclude_id -> where(base, [claim], claim.id != ^exclude_id)
    end
  end

  defp extract_record_tag(provenance) when is_binary(provenance),
    do: Regex.run(~r/\[base:[^\]\s]+\/[^\]\s]+\]/, provenance) |> List.wrap() |> List.first()

  defp extract_record_tag(_provenance), do: nil

  defp normalized_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
