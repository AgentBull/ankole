defmodule Ankole.Brain.Calibration do
  @moduledoc """
  Grading and calibration scoring of Takes.

  Owns the two Dreaming phases that measure prediction quality: `grade_takes`
  grades stale or expired active Takes against page evidence, and
  `calibration_profile` writes each holder's Brier scorecard into the fenced
  calibration section of the holder page. `brier/1` is the one owner of the
  score formula; the expert directory reads it for its per-expert card.
  """

  require Ash.Query

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

  @doc """
  Whether the next `grade_takes` round can run, for the Brain health surface.
  """
  @spec grading_status() :: %{status: String.t(), reason: String.t() | nil}
  def grading_status do
    case Config.dreaming_model() do
      nil -> %{status: "skipped", reason: "dreaming_model_not_configured"}
      _model -> %{status: "ready", reason: nil}
    end
  end

  defp candidates do
    stale_before = DateTime.add(DateTime.utc_now(), -@grade_stale_months * 30 * 86_400, :second)
    today = Date.utc_today()

    Ash.Query.filter(
      Claim,
      live_parent? and claim_type == :take and active == true and is_nil(resolved_at) and
        ((not is_nil(until_date) and until_date < ^today) or created_at < ^stale_before)
    )
  end

  defp expired?(%Claim{until_date: %Date{} = until_date}),
    do: Date.compare(until_date, Date.utc_today()) == :lt

  defp expired?(_take), do: false

  defp grade_batch(model, after_id, report) do
    batch =
      candidates()
      |> after_claim(after_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(@grade_batch_limit)
      |> Ankole.Ash.read!()

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
  defp after_claim(query, id), do: Ash.Query.filter(query, id > ^id)

  defp grading_context(nil), do: {:error, :dreaming_model_not_configured}

  # The grader acts as the Brain maintainer Agent, whose profile it calls, so a
  # resolution it writes carries that Principal's actor reference like a
  # Console resolve carries the Human's.
  defp grading_context(model) do
    with {:ok, maintainer_uid} <- Config.maintainer_subject_uid(),
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(model["provider_id"]),
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
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.name, &1.pack_name})

      grader =
        to_string(
          Ankole.ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: maintainer_uid})
        )

      {:ok, %{profile: model, generation: generation, domains: domains, grader: grader}}
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
           {:ok, result} <-
             Repo.transact_top_level(fn -> commit_grade_in_tx(take.id, input.hash, output) end) do
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
          |> Ash.Query.filter(
            current_external_fact? and object_slug == ^slug and
              (audience_scope == "world" or audience_scope == ^take.audience_scope)
          )
          |> Ash.Query.sort(valid_from: :desc, id: :desc)
          |> Ash.Query.limit(10)
          |> Ankole.Ash.read!()
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

  @doc false
  # Records one grade in the transaction of the `:commit_grade` action. The
  # locked Take must still be a grading candidate, and the grading input must
  # still give the hash that the model graded.
  def commit_grade_in_tx(take_id, input_hash, output) do
    take =
      Claim
      |> Ash.Query.filter(id == ^take_id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!()

    commit_current_grade(take, input_hash, output)
  end

  defp commit_current_grade(%Claim{active: true, resolved_at: nil} = take, hash, output) do
    with [_candidate] <-
           candidates()
           |> Ash.Query.filter(id == ^take.id)
           |> Ash.Query.select([:id])
           |> Ankole.Ash.read!(),
         {:ok, model} <- grading_context(Config.dreaming_model()),
         %{hash: ^hash, domains: domains} <- grading_input(model, take) do
      if take.graded_input_hash == hash do
        {:ok, :skip}
      else
        {:ok, _} =
          Ankole.Ash.update(take, :record_grade, %{
            graded_quality: output["quality"],
            graded_confidence: min(max(output["confidence"] * 1.0, 0.0), 1.0),
            graded_at: DateTime.utc_now(:microsecond),
            graded_input_hash: hash
          })

        assign_take_domains(take, List.wrap(output["domains"]), domains)

        with :ok <- resolve_expired(take, output["quality"], model.grader),
             do: {:ok, :graded}
      end
    else
      {:error, _reason} = error -> error
      _changed -> {:ok, :skip}
    end
  end

  defp commit_current_grade(_take, _hash, _output), do: {:ok, :skip}

  # A verdict on an expired Take is its resolution: the period is over and no
  # later evidence changes the outcome, so the Take leaves the grading queue
  # and enters the scorecards through the one resolve contract. An
  # unresolvable verdict keeps the Take in the queue for later evidence, and a
  # stale Take without a due date keeps only its grade because its period is
  # still open.
  defp resolve_expired(take, quality, grader)
       when quality in ["correct", "incorrect", "partial"] do
    if expired?(take) do
      resolution = %{
        resolved_quality: quality,
        resolved_outcome: resolved_outcome(quality),
        resolution_provenance: "dreaming grade"
      }

      with {:ok, _resolved} <- Claims.resolve_take_in_tx(take.id, resolution, grader),
           do: :ok
    else
      :ok
    end
  end

  defp resolve_expired(_take, _quality, _grader), do: :ok

  defp resolved_outcome("correct"), do: true
  defp resolved_outcome("incorrect"), do: false
  defp resolved_outcome("partial"), do: nil

  # Domain assignments feed the calibration scorecards; the unique
  # (take, domain) key makes grading reruns idempotent.
  defp assign_take_domains(take, names, domains) do
    names
    |> Enum.filter(&Map.has_key?(domains, &1))
    |> Enum.each(fn domain ->
      Ankole.Ash.create!(TakeDomainAssignment, :assign_once, %{
        id: UUIDv7.autogenerate(),
        take_claim_id: take.id,
        domain: domain,
        pack: Map.fetch!(domains, domain),
        assignment_provenance: "dreaming grade",
        confidence: 1.0,
        assigned_at: DateTime.utc_now(:microsecond)
      })
    end)
  end

  @doc false
  def calibration_profile do
    scored =
      Claim
      |> Ash.Query.filter(
        live_parent? and claim_type == :take and resolved_quality in ["correct", "incorrect"]
      )
      |> Ankole.Ash.read!()

    domain_assignments =
      TakeDomainAssignment
      |> Ankole.Ash.read!()
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
        case Repo.transact_top_level(fn ->
               Objects.update_object_in_tx(
                 object.slug,
                 %{body: body, expected_content_hash: object.content_hash},
                 :system
               )
             end) do
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
