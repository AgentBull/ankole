defmodule Ankole.Brain.Experts do
  @moduledoc """
  Expert routing: who in the organization knows about one topic.

  Candidates are entities whose type declares `expert_routing`; ranking
  aggregates the density, freshness, and calibration of the knowledge each
  candidate holds on the topic. Both layers of memory filtering apply to the
  evidence before it counts.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Repo

  @default_limit 5
  @freshness_halflife_days 90

  @type disclosure :: Ankole.Brain.Access.disclosure()

  @doc """
  Ranks expert candidates for one topic.
  """
  @spec who_knows(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def who_knows(querier_uid, topic, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())

    with {:ok, access} <- Access.for_querier(querier_uid),
         {:ok, recall} <-
           Recall.recall(querier_uid, %{query: topic, limit: 50}, disclosure: disclosure) do
      expert_types =
        SchemaType
        |> where([type], type.expert_routing == true)
        |> select([type], type.name)
        |> Repo.all()

      expert_slugs =
        Object
        |> where([object], object.type in ^expert_types and is_nil(object.deleted_at))
        |> select([object], object.slug)
        |> Repo.all()
        |> MapSet.new()

      now = DateTime.utc_now()

      experts =
        recall.claims
        |> Enum.filter(fn claim -> MapSet.member?(expert_slugs, claim.holder) end)
        |> Enum.group_by(& &1.holder)
        |> Enum.map(fn {holder, claims} ->
          %{
            holder: holder,
            evidence_count: length(claims),
            score: expert_score(claims, now),
            calibration: holder_calibration(holder, access, disclosure)
          }
        end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)
        |> Enum.map(&add_holder_card/1)

      {:ok, experts}
    end
  end

  defp expert_score(claims, now) do
    freshness =
      claims
      |> Enum.map(fn claim ->
        reference = claim.valid_from || now
        age_days = max(DateTime.diff(now, reference, :second) / 86_400, 0.0)
        :math.exp(-age_days / @freshness_halflife_days)
      end)
      |> Enum.sum()

    length(claims) + freshness
  end

  # The scorecard aggregates only takes the querier may reach and disclose:
  # resolved_count and Brier over unreachable evidence would leak aggregate
  # knowledge through the numbers. Resolved takes are no longer current, so
  # the current-state predicate stays out.
  defp holder_calibration(holder, access, disclosure) do
    resolved =
      Claim
      |> where([claim], claim.claim_type == "take" and claim.holder == ^holder)
      |> where([claim], claim.resolved_quality in ["correct", "incorrect"])
      |> Access.filter_claims(access)
      |> Repo.all()
      |> Access.filter_disclosable(& &1.audience_scope, disclosure)

    case resolved do
      [] ->
        nil

      takes ->
        brier =
          takes
          |> Enum.map(fn take ->
            outcome = if take.resolved_outcome, do: 1.0, else: 0.0
            :math.pow(take.weight - outcome, 2)
          end)
          |> Enum.sum()
          |> Kernel./(length(takes))
          |> Float.round(4)

        %{resolved_count: length(takes), brier: brier}
    end
  end

  defp add_holder_card(expert) do
    case Repo.get_by(Object, slug: expert.holder) do
      %Object{} = object -> Map.merge(expert, %{title: object.title, type: object.type})
      nil -> Map.merge(expert, %{title: expert.holder, type: nil})
    end
  end
end
