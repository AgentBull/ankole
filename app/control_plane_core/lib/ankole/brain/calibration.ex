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

  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.TakeDomainAssignment
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  @grade_batch_limit 50
  @grade_stale_months 6
  @calibration_start "<!-- brain:calibration:start -->"
  @calibration_end "<!-- brain:calibration:end -->"

  @doc false
  def grade_takes do
    case grading_context(Config.dreaming_model()) do
      {:ok, model} ->
        grade_batch(model, nil, %{status: :ok, graded: 0, candidates: 0, attempted: 0})

      {:error, :dreaming_model_not_configured} ->
        %{status: :skipped, reason: :dreaming_model_not_configured}

      {:error, reason} ->
        %{status: :failed, error: reason}
    end
  end

  defp candidates do
    stale_before = DateTime.add(DateTime.utc_now(), -@grade_stale_months * 30 * 86_400, :second)
    today = Date.to_iso8601(Date.utc_today())

    Claim
    |> Claims.filter_live_parents()
    |> where([claim], claim.claim_type == "take" and claim.active == true)
    |> where([claim], is_nil(claim.resolved_at))
    |> where(
      [claim],
      (not is_nil(claim.until_date) and claim.until_date < ^today) or
        claim.created_at < ^stale_before
    )
  end

  defp grade_batch(model, after_id, report) do
    batch =
      candidates()
      |> after_claim(after_id)
      |> order_by([claim], asc: claim.id)
      |> limit(@grade_batch_limit)
      |> Repo.all()

    report =
      Enum.reduce_while(batch, report, fn take, report ->
        result = grade_take(model, take)

        report = %{
          report
          | candidates: report.candidates + 1,
            attempted: report.attempted + if(result == :cached, do: 0, else: 1),
            graded: report.graded + if(result == :graded, do: 1, else: 0)
        }

        if report.attempted == @grade_batch_limit,
          do: {:halt, report},
          else: {:cont, report}
      end)

    if length(batch) == @grade_batch_limit and report.attempted < @grade_batch_limit,
      do: grade_batch(model, List.last(batch).id, report),
      else: report
  end

  defp after_claim(query, nil), do: query
  defp after_claim(query, id), do: where(query, [claim], claim.id > ^id)

  defp grading_context(nil), do: {:error, :dreaming_model_not_configured}

  defp grading_context(model) do
    with {:ok, provider} <- ProviderConfigs.fetch_active_provider(model["provider_id"]),
         {:ok, definition} <- Providers.fetch(provider.provider_kind),
         {:ok, connection} <-
           ProviderConfigs.runtime_connection(provider, %{"credential" => %{}}),
         {:ok, context} <-
           PrepareContext.build(
             definition,
             :language_model,
             %{
               "model" => model["model"],
               "provider_options" => Map.get(model, "provider_options", %{}),
               "connection_options" => connection
             },
             %{}
           ) do
      credential_keys =
        definition.settings
        |> Enum.filter(&(&1.scope == :credential))
        |> Enum.map(& &1.key)

      generation = {provider.provider_kind, Map.drop(context.settings, credential_keys)}

      domains =
        Ankole.Brain.Schemas.SchemaCalibrationDomain
        |> Repo.all()
        |> Map.new(&{&1.name, &1.pack_name})

      {:ok, %{profile: model, generation: generation, domains: domains}}
    end
  end

  defp grade_take(model, take) do
    input = grading_input(model, take)

    if input.hash == take.graded_input_hash do
      :cached
    else
      with {:ok, output} <-
             ModelCalls.complete_json(model.profile, input.prompt,
               caller: "brain.dreaming.calibration"
             ),
           quality when quality in ["correct", "incorrect", "partial", "unresolvable"] <-
             output["quality"],
           confidence when is_number(confidence) <- output["confidence"],
           {:ok, result} <- commit_grade(take.id, input.hash, output) do
        result
      else
        _invalid -> :skip
      end
    end
  end

  defp grading_input(model, take) do
    evidence =
      case take.object_slug do
        nil ->
          []

        slug ->
          Claim
          |> Claims.current_external_facts()
          |> where([claim], claim.object_slug == ^slug)
          |> order_by([claim], desc: claim.valid_from, desc: claim.id)
          |> limit(10)
          |> Repo.all()
      end

    evidence_text =
      Enum.map_join(evidence, "\n", fn fact ->
        "- [#{fact.holder}; #{fact.kind}; valid from #{fact.valid_from}] #{fact.claim}\n" <>
          "  Context: #{fact.context}\n  Provenance: #{fact.provenance}"
      end)

    domains = model.domains

    domain_line =
      case Map.keys(domains) do
        [] -> "none installed"
        names -> names |> Enum.sort() |> Enum.join(", ")
      end

    prompt = """
    Grade one prediction against the available evidence. Return one JSON
    object:
    {"quality":"correct|incorrect|partial|unresolvable","confidence":0.8,
     "domains":["<zero or more matching calibration domains>"]}

    Installed calibration domains: #{domain_line}

    Prediction (held by #{take.holder}, weight #{take.weight}): #{take.claim}
    Since: #{take.since_date || "not stated"}
    Until: #{take.until_date || "not stated"}
    Provenance: #{take.provenance}

    Evidence:
    #{evidence_text}
    """

    hash =
      {ModelCalls.request(model.profile, prompt), model.generation, domains}
      |> :erlang.term_to_binary([:deterministic])
      |> NativeKernel.xxh3_128_hex()

    %{prompt: prompt, domains: domains, hash: hash}
  end

  defp commit_grade(take_id, input_hash, output) do
    Repo.transact(fn repo ->
      take = repo.one(from claim in Claim, where: claim.id == ^take_id, lock: "FOR UPDATE")
      commit_current_grade(repo, take, input_hash, output)
    end)
  end

  defp commit_current_grade(repo, %Claim{active: true, resolved_at: nil} = take, hash, output) do
    with true <- repo.exists?(where(candidates(), [claim], claim.id == ^take.id)),
         {:ok, model} <- grading_context(Config.dreaming_model()),
         %{hash: ^hash, domains: domains} <- grading_input(model, take) do
      if take.graded_input_hash == hash do
        {:ok, :skip}
      else
        take
        |> Ecto.Changeset.change(
          graded_quality: output["quality"],
          graded_confidence: min(max(output["confidence"] * 1.0, 0.0), 1.0),
          graded_at: DateTime.utc_now(:microsecond),
          graded_input_hash: hash
        )
        |> repo.update!()

        assign_take_domains(repo, take, List.wrap(output["domains"]), domains)
        {:ok, :graded}
      end
    else
      _changed -> {:ok, :skip}
    end
  end

  defp commit_current_grade(_repo, _take, _hash, _output), do: {:ok, :skip}

  # Domain assignments feed the calibration scorecards; the unique
  # (take, domain) key makes grading reruns idempotent.
  defp assign_take_domains(repo, take, names, domains) do
    names
    |> Enum.filter(&Map.has_key?(domains, &1))
    |> Enum.each(fn domain ->
      repo.insert!(
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
        conflict_target: [:tenant_id, :take_claim_id, :domain]
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
