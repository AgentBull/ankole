defmodule Ankole.AIGateway.UsageLedger do
  @moduledoc """
  Append-only usage ledger for Agent and control-plane provider calls.

  The ledger is the single per-round fact table of model usage. Each row keeps
  the counts that the Provider reported and leaves an unreported count `nil`.
  A row names its capability: a language-model round counts tokens, and a
  generated image or a decision records what the call produced. Token quota
  windows, the usage of one Signal, and the Console summary read
  language-model rows only.
  Explicit subject credentials determine the origin before internal caller
  labels. Only Agent and Codex rows count toward Agent token quota windows;
  Brain, Applet, Pod file extraction, OIDC Human, and automatic compaction rows
  remain ledger-only.
  A ledger write failure never discards an already delivered provider response.
  """

  require Ash.Query

  alias Ankole.AIGateway.ChatGPTProtocol
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Usage
  alias Ankole.Logging

  @token_fields [
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :cache_creation_input_tokens,
    :reasoning_tokens
  ]

  @doc "Records one completed provider round of a classified LLM request."
  @spec record(map() | nil, String.t() | nil, map(), keyword()) :: :ok
  def record(runtime, subject_type, round, opts \\ [])

  def record(%{"capability" => "llm"} = runtime, subject_type, round, opts)
      when is_map(round) do
    with origin when not is_nil(origin) <-
           origin(runtime, subject_type, Keyword.get(opts, :caller)),
         %{} = response <- counted_round(round) do
      insert(runtime, response, CredentialAttempts.model_usage(response, opts), origin)
    else
      _uncounted -> :ok
    end
  end

  def record(_runtime, _subject_type, _round, _opts), do: :ok

  @doc """
  Records one completed call of an image, decision, speech, transcription, or
  OCR provider.

  `result` carries the Provider's `usage`. An image call records `quantity`
  generated images, one by default. A speech call records the `quantity` of
  characters that it turned into audio, a transcription call records the
  seconds of audio that the Provider reports, and an OCR call records the
  pages that the Provider processed. `request_context` attributes the call to
  the work that made it when the runtime does not carry that context itself.
  """
  @spec record_capability(map() | nil, String.t() | nil, map(), keyword()) :: :ok
  def record_capability(runtime, subject_type, result, opts \\ [])

  def record_capability(%{"capability" => capability} = runtime, subject_type, result, opts)
      when capability in ["image_generate", "decision", "speech", "transcription", "ocr"] and
             is_map(result) do
    runtime =
      case Keyword.get(opts, :request_context) do
        %{} = request_context -> Map.put(runtime, "request_context", request_context)
        _missing -> runtime
      end

    case origin(runtime, subject_type, Keyword.get(opts, :caller)) do
      nil ->
        :ok

      origin ->
        usage = Map.get(result, "usage") || %{}

        insert(
          runtime,
          result,
          usage,
          origin,
          capability_use(capability, usage, opts),
          Keyword.get(opts, :provider_request_model)
        )
    end
  end

  def record_capability(_runtime, _subject_type, _result, _opts), do: :ok

  defp capability_use("decision", usage, _opts),
    do: %{capability: :decision, provider_cost: provider_cost(usage)}

  defp capability_use("image_generate", usage, opts) do
    %{
      capability: :image_generate,
      unit: :image,
      quantity: Keyword.get(opts, :quantity, 1),
      provider_cost: provider_cost(usage)
    }
  end

  defp capability_use("speech", usage, opts) do
    %{
      capability: :speech,
      unit: :character,
      quantity: Keyword.fetch!(opts, :quantity),
      provider_cost: provider_cost(usage)
    }
  end

  # A started second counts as a whole one.
  defp capability_use("transcription", %{"seconds" => seconds} = usage, _opts)
       when is_number(seconds) and seconds >= 0 do
    %{
      capability: :transcription,
      unit: :second,
      quantity: ceil(seconds),
      provider_cost: provider_cost(usage)
    }
  end

  defp capability_use("transcription", usage, _opts),
    do: %{capability: :transcription, provider_cost: provider_cost(usage)}

  defp capability_use("ocr", %{"pages" => pages}, _opts) when is_integer(pages),
    do: %{capability: :ocr, unit: :page, quantity: pages}

  defp capability_use("ocr", _usage, _opts), do: %{capability: :ocr}

  defp provider_cost(%{"cost" => cost}) when is_number(cost) and cost >= 0,
    do: Decimal.new("#{cost}")

  defp provider_cost(_usage), do: nil

  @doc """
  Returns the work attribution of a request context, without its transport and
  model hints, for a side call that must be counted for the same work.
  """
  @spec attribution(map() | nil) :: map()
  def attribution(request_context) when is_map(request_context),
    do: Map.take(request_context, ~w(session_id signal_id human_uid job_id attempts))

  def attribution(_request_context), do: %{}

  @doc """
  Sums Agent and Codex tokens from `window_started_at` onwards.

  A round whose counts the Provider did not report adds nothing.
  """
  @spec window_tokens(String.t(), DateTime.t()) :: non_neg_integer()
  def window_tokens(subject_uid, %DateTime{} = window_started_at) when is_binary(subject_uid) do
    totals =
      UsageRecord
      |> Ash.Query.filter(
        subject_uid == ^subject_uid and inserted_at >= ^window_started_at and
          origin in [:agent, :codex] and capability == :llm
      )
      |> Ankole.Ash.aggregate!([
        {:input, :sum, field: :input_tokens, default: 0},
        {:output, :sum, field: :output_tokens, default: 0}
      ])

    totals.input + totals.output
  end

  @doc """
  Sums the counted rounds of one Signal's work, or returns `nil` when none was counted.

  The result names each model that served the work. A token total is `nil`
  when no round reported that count, and `reported_rounds` says how many of
  the `rounds` reported their input or output.
  """
  @spec turn_usage(String.t() | nil) :: map() | nil
  def turn_usage(signal_id) when is_binary(signal_id) do
    UsageRecord
    |> Ash.Query.filter(signal_id == ^signal_id and capability == :llm)
    |> Ash.Query.sort(id: :asc)
    |> Ankole.Ash.read!()
    |> case do
      [] -> nil
      rows -> Map.put(usage_totals(rows), "models", model_usage(rows))
    end
  end

  def turn_usage(_signal_id), do: nil

  @summary_page 5_000
  @summary_fields [:id, :inserted_at, :subject_uid, :human_uid, :origin] ++ @token_fields

  @doc """
  Sums the tenant's counted rounds from `since` onwards in total, by subject
  Principal (`by_agent`), by Human, and by origin.

  Each row says how many of its rounds reported their tokens. Rounds that
  serve no Human share the row whose `key` is `nil`. `agent_subjects` lists the
  subjects that made `agent` or `codex` rounds, which only an Agent makes, so
  a reader can still tell that a deleted subject was an Agent.
  """
  # shortcut: reads each row of the window once and sums it in Elixir, so the cost
  # grows linearly with the window's rounds; move the grouping into an SQL read
  # model when a window holds too many rounds to read per request.
  @spec window_summary(DateTime.t()) :: map()
  def window_summary(%DateTime{} = since) do
    groups =
      fold_window(since, nil, %{
        total: %{},
        by_agent: %{},
        by_human: %{},
        by_origin: %{},
        agent_subjects: MapSet.new()
      })

    %{
      total: summary_row(nil, Map.get(groups.total, nil, empty_totals())),
      by_agent: summary_rows(groups.by_agent),
      by_human: summary_rows(groups.by_human),
      by_origin: summary_rows(groups.by_origin),
      agent_subjects: groups.agent_subjects
    }
  end

  @doc """
  Sums the tenant's calls that are not language-model rounds from `since`
  onwards, by capability and unit.

  Each row says how many calls it counts, the `quantity` that they produced in
  their unit, such as pages or seconds, and the cost that the Providers
  reported. `quantity` is `nil` for calls that record no unit, and
  `provider_cost` is `nil` when no call of the row reported a cost.
  """
  # shortcut: reads each row of the window once, like `window_summary/1`; move
  # the grouping into an SQL read model together with it.
  @spec capability_summary(DateTime.t()) :: [map()]
  def capability_summary(%DateTime{} = since) do
    since
    |> fold_capabilities(nil, %{})
    |> Enum.map(fn {{capability, unit}, totals} ->
      Map.merge(totals, %{
        capability: Atom.to_string(capability),
        unit: unit && Atom.to_string(unit),
        provider_cost: totals.provider_cost && Decimal.to_float(totals.provider_cost)
      })
    end)
    |> Enum.sort_by(&{&1.capability, &1.unit || ""})
  end

  defp fold_capabilities(since, last, groups) do
    rows =
      UsageRecord
      |> capability_page(since, last)
      |> Ash.Query.select([:id, :inserted_at, :capability, :unit, :quantity, :provider_cost])
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.Query.limit(@summary_page)
      |> Ankole.Ash.read!()

    groups =
      Enum.reduce(rows, groups, fn row, groups ->
        Map.update(
          groups,
          {row.capability, row.unit},
          %{calls: 1, quantity: row.quantity, provider_cost: row.provider_cost},
          &%{
            calls: &1.calls + 1,
            quantity: sum(&1.quantity, row.quantity),
            provider_cost: sum(&1.provider_cost, row.provider_cost)
          }
        )
      end)

    case rows do
      rows when length(rows) == @summary_page -> fold_capabilities(since, List.last(rows), groups)
      _last_page -> groups
    end
  end

  defp capability_page(query, since, nil),
    do: Ash.Query.filter(query, capability != :llm and inserted_at >= ^since)

  defp capability_page(query, _since, %{inserted_at: at, id: id}) do
    Ash.Query.filter(
      query,
      capability != :llm and (inserted_at > ^at or (inserted_at == ^at and id > ^id))
    )
  end

  # A value that no call reported stays nil instead of becoming zero.
  defp sum(nil, value), do: value
  defp sum(total, nil), do: total
  defp sum(%Decimal{} = total, %Decimal{} = value), do: Decimal.add(total, value)
  defp sum(total, value), do: total + value

  # Keyset pages on `(inserted_at, id)` follow the `(tenant_id, inserted_at)` index,
  # so every page starts where the previous one ended.
  defp fold_window(since, last, groups) do
    rows =
      UsageRecord
      |> window_page(since, last)
      |> Ash.Query.select(@summary_fields)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.Query.limit(@summary_page)
      |> Ankole.Ash.read!()

    groups =
      Enum.reduce(rows, groups, fn row, groups ->
        groups
        |> add_to(:total, nil, row)
        |> add_to(:by_agent, row.subject_uid, row)
        |> add_to(:by_human, row.human_uid, row)
        |> add_to(:by_origin, Atom.to_string(row.origin), row)
        |> add_agent_subject(row)
      end)

    case rows do
      rows when length(rows) == @summary_page -> fold_window(since, List.last(rows), groups)
      _last_page -> groups
    end
  end

  defp window_page(query, since, nil),
    do: Ash.Query.filter(query, capability == :llm and inserted_at >= ^since)

  defp window_page(query, _since, %{inserted_at: at, id: id}) do
    Ash.Query.filter(
      query,
      capability == :llm and (inserted_at > ^at or (inserted_at == ^at and id > ^id))
    )
  end

  defp add_to(groups, group, key, row),
    do: update_in(groups, [group, Access.key(key, empty_totals())], &add_round(&1, row))

  defp add_agent_subject(groups, %{origin: origin, subject_uid: uid})
       when origin in [:agent, :codex],
       do: Map.update!(groups, :agent_subjects, &MapSet.put(&1, uid))

  defp add_agent_subject(groups, _row), do: groups

  defp summary_rows(group) do
    group
    |> Enum.map(fn {key, totals} -> summary_row(key, totals) end)
    |> Enum.sort_by(&{-((&1.input_tokens || 0) + (&1.output_tokens || 0)), -&1.rounds})
  end

  defp summary_row(key, totals) do
    %{
      key: key,
      rounds: totals["rounds"],
      reported_rounds: totals["reported_rounds"],
      input_tokens: totals["input_tokens"],
      output_tokens: totals["output_tokens"],
      cached_input_tokens: totals["cached_input_tokens"],
      cache_creation_input_tokens: totals["cache_creation_input_tokens"],
      reasoning_tokens: totals["reasoning_tokens"]
    }
  end

  # The most used model comes first. Models with equal rounds keep the order in
  # which they first served.
  defp model_usage(rows) do
    rows
    |> Enum.map(&model_key/1)
    |> Enum.uniq()
    |> Enum.map(fn {model, provider_model, profile, served} = key ->
      rows
      |> Enum.filter(&(model_key(&1) == key))
      |> usage_totals()
      |> Map.put("model", model)
      |> Ankole.Attrs.maybe_put("provider_model", provider_model)
      |> Ankole.Attrs.maybe_put("model_profile", profile)
      |> Ankole.Attrs.maybe_put("served_profile", if(served != profile, do: served))
    end)
    |> Enum.sort_by(&(-&1["rounds"]))
  end

  defp model_key(row), do: {row.model, row.provider_model, row.model_profile, row.served_profile}

  defp usage_totals(rows), do: Enum.reduce(rows, empty_totals(), &add_round(&2, &1))

  defp empty_totals do
    Map.new(["rounds", "reported_rounds" | Enum.map(@token_fields, &Atom.to_string/1)], fn
      field when field in ["rounds", "reported_rounds"] -> {field, 0}
      field -> {field, nil}
    end)
  end

  # A round reports when the Provider gave its input or output count.
  defp add_round(totals, row) do
    reported = if is_nil(row.input_tokens) and is_nil(row.output_tokens), do: 0, else: 1

    totals = %{
      totals
      | "rounds" => totals["rounds"] + 1,
        "reported_rounds" => totals["reported_rounds"] + reported
    }

    Enum.reduce(@token_fields, totals, fn field, totals ->
      Map.update!(totals, Atom.to_string(field), &add_count(&1, Map.fetch!(row, field)))
    end)
  end

  defp add_count(total, nil), do: total
  defp add_count(nil, count), do: count
  defp add_count(total, count), do: total + count

  defp counted_round(%{"type" => type, "response" => %{} = response})
       when type in ["response.completed", "response.incomplete"],
       do: response

  defp counted_round(%{"status" => status} = response)
       when status in ["completed", "incomplete"],
       do: response

  defp counted_round(_round), do: nil

  defp insert(
         runtime,
         response,
         usage,
         origin,
         capability_use \\ %{},
         provider_request_model \\ nil
       ) do
    request_context = Map.get(runtime, "request_context") || %{}
    counts = Usage.counts(usage)
    requested_model = Map.get(runtime, "model")
    {model_profile, served_profile} = profiles(runtime, request_context)

    attrs = %{
      subject_uid: Map.get(runtime, "subject_uid"),
      origin: origin,
      model: "#{Map.get(runtime, "provider_id")}/#{requested_model}",
      provider_model: reported_model(response, provider_request_model || requested_model),
      model_profile: Ankole.Attrs.optional_text(model_profile),
      served_profile: Ankole.Attrs.optional_text(served_profile),
      input_tokens: counts.input_tokens,
      output_tokens: counts.output_tokens,
      cached_input_tokens: counts.cached_input_tokens,
      cache_creation_input_tokens: counts.cache_creation_input_tokens,
      reasoning_tokens: counts.reasoning_tokens,
      human_uid: human_uid(origin, runtime, request_context),
      session_id: Ankole.Attrs.optional_text(Map.get(request_context, "session_id")),
      signal_id: uuid(Map.get(request_context, "signal_id")),
      job_id: positive_integer(Map.get(request_context, "job_id")),
      attempt: non_negative_integer(Map.get(request_context, "attempts"))
    }

    write(Map.merge(attrs, capability_use))
  end

  # A profile selector names its profile in the runtime. A caller that sends the
  # profile's frozen `provider/model` names the profile in its request context.
  defp profiles(%{"profile" => profile} = runtime, _request_context) when is_binary(profile),
    do: {profile, Map.get(runtime, "served_profile")}

  defp profiles(_runtime, request_context),
    do: {Map.get(request_context, "model_profile"), Map.get(request_context, "served_profile")}

  # The kernel answers with the requested model when the Provider names none.
  # Capability calls can also name the deployment sent upstream, so a different
  # response model identifies the model that actually served the round.
  defp reported_model(%{"model" => model}, requested_model)
       when is_binary(model) and model != requested_model,
       do: Ankole.Attrs.optional_text(model)

  defp reported_model(_response, _requested_model), do: nil

  # The attribution columns are optional. A malformed value must not fail the
  # quota row, so it is dropped instead of rejected.
  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

  # An OIDC Human calls for itself; every other caller names the Human its work serves.
  defp human_uid(:oidc_human, runtime, _request_context),
    do: principal_uid(Map.get(runtime, "subject_uid"))

  defp human_uid(_origin, _runtime, request_context),
    do: principal_uid(Map.get(request_context, "human_uid"))

  defp principal_uid(value) when is_binary(value) do
    case Ankole.Ecto.PrincipalKey.cast(value) do
      {:ok, uid} -> uid
      _invalid -> nil
    end
  end

  defp principal_uid(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp write(attrs) do
    case Ankole.Ash.create(UsageRecord, :record_round, attrs) do
      {:ok, _record} -> :ok
      {:error, error} -> write_failed(attrs, Exception.message(error))
    end
  rescue
    error -> write_failed(attrs, Exception.message(error))
  end

  defp write_failed(attrs, reason) do
    Logging.warning(
      "ai_gateway.usage_ledger.write_failed",
      "Usage row not recorded",
      %{subject_uid: attrs.subject_uid, reason: reason}
    )

    :ok
  end

  defp origin(runtime, "agent", _caller) do
    if ChatGPTProtocol.codex_client?(Map.get(runtime, "request_context", %{})),
      do: :codex,
      else: :agent
  end

  defp origin(_runtime, "oidc_human", _caller), do: :oidc_human
  defp origin(_runtime, nil, "compaction." <> _stage), do: :compaction
  defp origin(_runtime, nil, "pod_applet"), do: :applet
  defp origin(_runtime, nil, "pod_files"), do: :pod_files
  defp origin(_runtime, nil, "brain"), do: :brain

  defp origin(_runtime, nil, "brain." <> _stage), do: :brain
  defp origin(_runtime, _subject_type, _caller), do: nil
end
