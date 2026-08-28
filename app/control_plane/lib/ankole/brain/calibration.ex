defmodule Ankole.Brain.Calibration do
  @moduledoc """
  Grading and calibration scoring of Takes.

  Owns the two Dreaming phases that measure prediction quality: `grade_takes`
  grades stale or expired active Takes against page evidence, and
  `calibration_profile` writes each holder's Brier scorecard into the fenced
  calibration section of the holder page. `brier/1` is the one owner of the
  score formula; the expert directory reads it for its per-expert card.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.TakeDomainAssignment
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @grade_batch_limit 50
  @grade_stale_months 6
  @calibration_start "<!-- brain:calibration:start -->"
  @calibration_end "<!-- brain:calibration:end -->"

  @doc false
  def grade_takes do
    case Config.dreaming_model() do
      nil ->
        %{status: :skipped, reason: :dreaming_model_not_configured}

      model ->
        stale_before =
          DateTime.add(DateTime.utc_now(), -@grade_stale_months * 30 * 86_400, :second)

        today = Date.to_iso8601(Date.utc_today())

        takes =
          Claim
          |> Claims.filter_live_parents()
          |> where([claim], claim.claim_type == "take" and claim.active == true)
          |> where([claim], is_nil(claim.resolved_at))
          |> where(
            [claim],
            (not is_nil(claim.until_date) and claim.until_date < ^today) or
              claim.created_at < ^stale_before
          )
          |> limit(@grade_batch_limit)
          |> Repo.all()

        graded = Enum.count(takes, &(grade_take(model, &1) == :ok))
        %{status: :ok, graded: graded, candidates: length(takes)}
    end
  end

  defp grade_take(model, take) do
    evidence =
      case take.object_slug do
        nil ->
          []

        slug ->
          Claim
          |> Claims.current_external_facts()
          |> where([claim], claim.object_slug == ^slug)
          |> order_by([claim], desc: claim.valid_from)
          |> limit(10)
          |> Repo.all()
      end

    evidence_text = Enum.map_join(evidence, "\n", fn fact -> "- #{fact.claim}" end)

    domains =
      Ankole.Brain.Schemas.SchemaCalibrationDomain
      |> Repo.all()
      |> Map.new(&{&1.name, &1.pack_name})

    domain_line =
      case Map.keys(domains) do
        [] -> "none installed"
        names -> Enum.join(names, ", ")
      end

    prompt = """
    Grade one prediction against the available evidence. Return one JSON
    object:
    {"quality":"correct|incorrect|partial|unresolvable","confidence":0.8,
     "domains":["<zero or more matching calibration domains>"]}

    Installed calibration domains: #{domain_line}

    Prediction (held by #{take.holder}, weight #{take.weight}): #{take.claim}
    Until: #{take.until_date || "not stated"}

    Evidence:
    #{evidence_text}
    """

    with {:ok, output} <- ModelCalls.complete_json(model, prompt),
         quality when quality in ["correct", "incorrect", "partial", "unresolvable"] <-
           output["quality"],
         confidence when is_number(confidence) <- output["confidence"] do
      take
      |> Ecto.Changeset.change(
        graded_quality: quality,
        graded_confidence: min(max(confidence * 1.0, 0.0), 1.0),
        graded_at: DateTime.utc_now(:microsecond)
      )
      |> Repo.update!()

      assign_take_domains(take, List.wrap(output["domains"]), domains)

      :ok
    else
      _invalid -> :skip
    end
  end

  # Domain assignments feed the calibration scorecards; the unique
  # (take, domain) key makes grading reruns idempotent.
  defp assign_take_domains(take, names, domains) do
    names
    |> Enum.filter(&Map.has_key?(domains, &1))
    |> Enum.each(fn domain ->
      Repo.insert!(
        %TakeDomainAssignment{
          id: UUIDv7.autogenerate(),
          take_claim_id: take.id,
          domain: domain,
          pack: Map.fetch!(domains, domain),
          assignment_provenance: "dreaming grade",
          confidence: 1.0,
          assigned_at: DateTime.utc_now(:microsecond)
        },
        on_conflict: :nothing,
        conflict_target: [:take_claim_id, :domain]
      )
    end)
  end

  @doc false
  def calibration_profile do
    scored =
      Claim
      |> Claims.filter_live_parents()
      |> where([claim], claim.claim_type == "take")
      |> where([claim], claim.resolved_quality in ["correct", "incorrect"])
      |> Repo.all()

    domain_assignments =
      TakeDomainAssignment
      |> Repo.all()
      |> Enum.group_by(& &1.take_claim_id, & &1.domain)

    profiles =
      scored
      |> Enum.group_by(& &1.holder)
      |> Enum.map(fn {holder, takes} ->
        {holder, scorecard(takes, domain_assignments)}
      end)

    updated =
      Enum.count(profiles, fn {holder, card} -> update_calibration_section(holder, card) end)

    %{status: :ok, holders: length(profiles), updated: updated}
  end

  @doc """
  Brier score over resolved binary takes: `mean((weight - outcome)^2)`,
  rounded to four decimals. The list must be non-empty.
  """
  @spec brier([Claim.t()]) :: float()
  def brier(takes) do
    scores =
      Enum.map(takes, fn take ->
        outcome = if take.resolved_outcome, do: 1.0, else: 0.0
        :math.pow(take.weight - outcome, 2)
      end)

    Float.round(Enum.sum(scores) / length(scores), 4)
  end

  defp scorecard(takes, domain_assignments) do
    overall = brier(takes)

    domains =
      takes
      |> Enum.flat_map(fn take ->
        domain_assignments
        |> Map.get(take.id, [])
        |> Enum.map(&{&1, take})
      end)
      |> Enum.group_by(fn {domain, _take} -> domain end, fn {_domain, take} -> take end)
      |> Enum.map(fn {domain, domain_takes} ->
        %{domain: domain, count: length(domain_takes), brier: brier(domain_takes)}
      end)
      |> Enum.sort_by(& &1.domain)

    %{count: length(takes), brier: overall, domains: domains}
  end

  defp update_calibration_section(holder, card) do
    with {:ok, object} <- Objects.get_by_slug(holder) do
      section =
        [
          @calibration_start,
          "## Calibration",
          "",
          "Resolved takes: #{card.count}; Brier score: #{card.brier}.",
          Enum.map_join(card.domains, "\n", fn domain ->
            "- #{domain.domain}: #{domain.count} resolved, Brier #{domain.brier}"
          end),
          @calibration_end
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      body = replace_calibration_section(object.body, section)

      if body == object.body do
        false
      else
        case Objects.update_object(
               object.slug,
               %{body: body, expected_content_hash: object.content_hash},
               :system
             ) do
          {:ok, _object} -> true
          {:error, _reason} -> false
        end
      end
    else
      {:error, :not_found} -> false
    end
  end

  defp replace_calibration_section(body, section) do
    pattern =
      ~r/#{Regex.escape(@calibration_start)}[\s\S]*?#{Regex.escape(@calibration_end)}/u

    if Regex.match?(pattern, body) do
      Regex.replace(pattern, body, section)
    else
      String.trim_trailing(body) <> "\n\n" <> section <> "\n"
    end
  end
end
