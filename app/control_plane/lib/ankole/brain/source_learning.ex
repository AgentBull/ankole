defmodule Ankole.Brain.SourceLearning do
  @moduledoc """
  Learning from registered `file` and `url` Sources.

  A learning run fetches the content, keeps one `media` Object per Source,
  chunks it for retrieval, and extracts Claims when the object type is
  extractable. Runs execute as one Oban job per Source; model extraction
  happens before the commit transaction, and the commit re-checks the
  Source row under lock, so a run that raced an archive or another
  revision writes nothing. `upstream_revision` advances only after every
  write of the run succeeded, so a failed run stays learnable instead of
  being recorded as done.

  Relearning a changed Source expires the current facts of the previous
  revision (keyed by `provenance_session`) in the same transaction, so the
  current claims always reflect the current source content; expired rows
  keep the history. Whole-book absorption is the upper bound of this same
  path: every window of extractable content enters extraction, not a
  truncated prefix.

  `url` Sources use the maintainer Agent's `web_fetch` profile first and
  fall back to the Worker's supervised `ankole-browser` runtime when that
  profile is absent or its provider request fails. Both paths return readable
  text; a raw HTTP body would put HTML markup into chunks and claims. `file`
  Sources accept UTF-8 text only and reject binary content loudly.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Sources
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.JSON
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Security.SSRFFilter
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfig

  @max_content_bytes 10 * 1024 * 1024
  @extraction_window_chars 12_000
  @rendered_fetch_timeout_ms 330_000

  @doc """
  Registers one file or url Source.
  """
  @spec register_source(map()) :: {:ok, Source.t()} | {:error, term()}
  def register_source(attrs) when is_map(attrs) do
    with :ok <- validate_kind(attrs[:kind]),
         :ok <- validate_default_scope(attrs[:default_audience_scope]) do
      Sources.create(%{
        upstream_id: attrs[:upstream_id],
        kind: attrs[:kind],
        name: attrs[:name],
        default_audience_scope: attrs[:default_audience_scope] || "world",
        config: attrs[:config] || %{}
      })
    end
  end

  @doc """
  Validates one Source and enqueues its learning run. Only `file` and `url`
  Sources have a learning run; other kinds reject before the queue instead
  of failing inside the job.
  """
  @spec enqueue_learn(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def enqueue_learn(source_id) do
    with :ok <- ensure_enabled(),
         {:ok, source} <- fetch_source(source_id),
         :ok <- validate_kind(source.kind),
         :ok <- Sources.ensure_active(source),
         {:ok, _job} <- Ankole.Brain.Jobs.LearnSource.enqueue(source.id) do
      {:ok, %{status: :enqueued}}
    end
  end

  @doc """
  Runs one learning pass for one Source.
  """
  @spec learn(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def learn(source_id) do
    with :ok <- ensure_enabled(),
         {:ok, source} <- fetch_source(source_id),
         :ok <- Sources.ensure_active(source),
         {:ok, content} <- fetch_content(source) do
      fingerprint = NativeKernel.xxh3_128_hex(content)

      if source.upstream_revision == fingerprint do
        {:ok, %{status: :unchanged, fingerprint: fingerprint}}
      else
        learn_content(source, content, fingerprint)
      end
    end
  end

  defp learn_content(source, content, fingerprint) do
    scope = source.default_audience_scope || "world"
    slug = source_object_slug(source)

    object_attrs = %{
      slug: slug,
      subtype: source.config["subtype"] || default_subtype(source.kind),
      title: source.name,
      body: Markdoc.wrap(content, scope)
    }

    # Model extraction is the slow, fallible part and must not hold locks;
    # any failed window aborts the run with no state change.
    with {:ok, extraction} <- extract_items(slug, source.name, content) do
      commit_run(source, object_attrs, extraction, scope, fingerprint)
    end
  end

  # One transaction owns every write of the run. The locked re-read fences
  # two races: an archive during the fetch or extraction (the archived
  # Source must not gain new memory), and a revision that advanced since
  # this run read it (the later content must not be overwritten by the
  # earlier run's late commit).
  defp commit_run(source, object_attrs, extraction, scope, fingerprint) do
    session = provenance_session(source)

    result =
      Repo.transact(fn repo ->
        with {:ok, current} <- Sources.lock_active(repo, source),
             :ok <- ensure_same_revision(current, source.upstream_revision),
             {:ok, object} <- Objects.upsert_source_projection(current, object_attrs, repo: repo),
             expired = Claims.expire_source_session_facts(repo, object.slug, session),
             {:ok, written} <- write_claims(repo, object, extraction.items, scope, session),
             :ok <- ensure_extraction_written(extraction.items, written),
             {:ok, _source} <- Sources.record_revision(repo, current, fingerprint) do
          {:ok,
           %{
             status: :learned,
             object_slug: object.slug,
             windows: extraction.windows,
             claims: written.claims,
             claims_expired: expired,
             rejected: written.rejected,
             reject_reasons: written.reject_reasons
           }}
        end
      end)

    with {:ok, %{rejected: rejected} = report} <- result do
      if rejected > 0 do
        Logging.warning(
          "brain.source_learning.items_rejected",
          "extracted items failed write validation",
          %{source_id: source.id, rejected: rejected, reasons: report[:reject_reasons] || []}
        )
      end

      {:ok, Map.delete(report, :reject_reasons)}
    end
  end

  defp ensure_same_revision(%Source{upstream_revision: current}, expected)
       when current == expected,
       do: :ok

  defp ensure_same_revision(%Source{}, _expected), do: {:error, :stale_run}

  # An extraction whose items all fail write validation is a model-quality
  # failure, not new knowledge. Committing it would keep the expired old
  # facts gone and advance the fingerprint, so the loss would read as
  # `unchanged` forever; the rollback keeps the old memory and a later run
  # retries the same revision. An extraction with no items stays a commit:
  # the document really carries nothing to learn.
  defp ensure_extraction_written(items, %{claims: 0, reject_reasons: reasons}) when items != [],
    do: {:error, {:all_items_rejected, reasons}}

  defp ensure_extraction_written(_items, _written), do: :ok

  # Extraction

  # Extraction covers every window of the content when the object type is
  # extractable. A model failure aborts the run instead of counting as an
  # empty result: recording `learned` with zero claims would freeze the
  # fingerprint and skip the content forever.
  defp extract_items(slug, title, content) do
    if extractable_type?(slug) do
      case Config.extraction_model() do
        nil ->
          {:error, :extraction_model_not_configured}

        model ->
          content
          |> content_windows(@extraction_window_chars)
          |> Enum.reduce_while({:ok, %{windows: 0, items: []}}, fn window, {:ok, acc} ->
            case extract_window(model, title, window) do
              {:ok, items} ->
                {:cont, {:ok, %{windows: acc.windows + 1, items: acc.items ++ items}}}

              {:error, reason} ->
                {:halt, {:error, {:extraction_failed, reason}}}
            end
          end)
      end
    else
      {:ok, %{windows: 0, items: []}}
    end
  end

  defp extractable_type?(slug) do
    type =
      case Objects.get_by_slug(slug) do
        {:ok, object} -> object.type
        {:error, :not_found} -> "media"
      end

    SchemaType
    |> where([schema_type], schema_type.name == ^type)
    |> select([schema_type], schema_type.extractable)
    |> Repo.one() || false
  end

  # `String.split_at/2` walks only the split-off window, so the whole pass
  # stays linear in the content size.
  defp content_windows(content, window) do
    Stream.unfold(content, fn
      "" -> nil
      rest -> String.split_at(rest, window)
    end)
    |> Enum.to_list()
  end

  defp extract_window(model, title, window_text) do
    prompt = """
    Extract durable factual claims from this source excerpt. Return one JSON
    object: {"items":[{"claim":"...","kind":"event|preference|commitment|belief|fact","notability":"high|medium|low","confidence":0.75,"context":"..."}]}

    Rules: one independently changeable assertion per item; multiples of
    0.05 for confidence; skip anything without long-term value.

    Source: #{title}
    Excerpt:
    #{window_text}
    """

    case ModelCalls.complete_json(model, prompt) do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _invalid_output} -> {:error, :invalid_extraction_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # Claims write with deferred embedding: Self-healing embeds them within
  # its next sweep, and dedup is pointless here because the previous
  # revision's claims were just expired. Item-level validation rejects are
  # counted and logged; they must not wedge the source forever.
  defp write_claims(repo, object, items, scope, session) do
    now = DateTime.utc_now(:microsecond)

    written =
      Enum.reduce(items, %{claims: 0, rejected: 0, reject_reasons: []}, fn item, acc ->
        attrs = %{
          object_slug: object.slug,
          claim: item["claim"],
          kind: item["kind"],
          holder: "world",
          audience_scope: scope,
          notability: item["notability"] || "medium",
          confidence: Claims.snap_to_grid(item["confidence"]),
          context: item["context"],
          valid_from: now,
          provenance: "source: #{object.title}",
          provenance_session: session
        }

        case Claims.write_fact(attrs, :system, repo: repo, dedup: false, embed: false) do
          {:ok, _result} ->
            Map.update!(acc, :claims, &(&1 + 1))

          {:error, reason} ->
            acc
            |> Map.update!(:rejected, &(&1 + 1))
            |> Map.update!(:reject_reasons, &[inspect(reason) | &1])
        end
      end)

    {:ok,
     Map.update!(written, :reject_reasons, fn reasons ->
       reasons |> Enum.reverse() |> Enum.uniq() |> Enum.take(5)
     end)}
  end

  defp provenance_session(%Source{id: id}), do: "source:" <> id

  defp source_object_slug(%Source{} = source) do
    hash = source.id |> NativeKernel.xxh3_128_hex() |> String.slice(0, 12)
    "media/source-#{hash}"
  end

  defp default_subtype("url"), do: "article"
  defp default_subtype("file"), do: "book"

  # Content fetch

  defp fetch_content(%Source{kind: "file", upstream_id: path}) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size <= @max_content_bytes,
         {:ok, content} <- File.read(path) do
      if String.valid?(content),
        do: {:ok, content},
        else: {:error, :source_content_not_text}
    else
      false -> {:error, :source_content_too_large}
      {:error, reason} -> {:error, {:source_unreadable, reason}}
    end
  end

  defp fetch_content(%Source{kind: "url", upstream_id: url}) do
    case Config.web_fetch_model() do
      nil ->
        fetch_with_local_browser(url)

      model ->
        case fetch_with_provider(url, model) do
          {:provider_failed, provider_reason} ->
            case fetch_with_local_browser(url) do
              {:ok, _text} = success ->
                success

              {:error, local_reason} ->
                {:error,
                 {:source_fetch_failed, %{provider: provider_reason, local_browser: local_reason}}}
            end

          result ->
            result
        end
    end
  end

  defp fetch_content(%Source{kind: kind}), do: {:error, {:unsupported_source_kind, kind}}

  defp fetch_with_provider(url, model) do
    request =
      %{
        "model" => model["provider_id"] <> "/" <> model["model"],
        "urls" => [url]
      }
      |> maybe_put_provider_options(model)

    with {:ok, subject_uid} <- Config.maintainer_subject_uid() do
      case AIGateway.create_web_fetch(subject_uid, request) do
        {:ok, %{body: body}} -> web_fetch_body(body)
        {:error, reason} -> {:provider_failed, reason}
      end
    else
      {:error, reason} -> {:provider_failed, reason}
    end
  end

  defp fetch_with_local_browser(url) do
    with {:ok, agent_uid} <- Config.maintainer_subject_uid(),
         {:ok, worker_env} <- WorkerEnv.effective_env(agent_uid),
         {:ok, ssrf_filter?} <- SSRFFilter.enabled?(agent_uid),
         {:ok, %{value: idle_ttl_ms}} <- WorkerWebFetchConfig.resolve(agent_uid),
         [route | _rest] <- WorkerPool.ready_worker_routes(),
         request = %FabricProto.RenderedWebFetchRequest{
           urls: [url],
           worker_env: worker_env,
           ssrf_filter: ssrf_filter?,
           idle_ttl_ms: idle_ttl_ms
         },
         {:ok, payload} <-
           Broker.request_rpc(route, "web_fetch.rendered", encode_proto(request),
             timeout_ms: @rendered_fetch_timeout_ms,
             request_id: "brain-rendered-web-fetch-#{Ecto.UUID.generate()}"
           ),
         {:ok, response} <- FabricProto.RenderedWebFetchResponse.decode(payload),
         {:ok, body} <- JSON.decode(response.body_json) do
      web_fetch_body(body)
    else
      [] -> {:error, :no_worker_available}
      :error -> {:error, :rendered_fetch_config_unresolved}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_rendered_fetch_response}
    end
  end

  defp web_fetch_body(%{"results" => [result | _rest]}), do: web_fetch_text(result)
  defp web_fetch_body(_body), do: {:error, :source_fetch_empty}

  defp maybe_put_provider_options(request, model) do
    case model["provider_options"] do
      options when is_map(options) and map_size(options) > 0 ->
        Map.put(request, "provider_options", options)

      _empty ->
        request
    end
  end

  defp encode_proto(struct) do
    {iodata, _size} = struct.__struct__.encode!(struct)
    IO.iodata_to_binary(iodata)
  end

  defp web_fetch_text(result) do
    error = result["error"]
    text = result["text"]

    cond do
      is_binary(error) and error != "" ->
        {:error, {:source_fetch_failed, error}}

      is_binary(text) and String.trim(text) != "" ->
        if byte_size(text) <= @max_content_bytes,
          do: {:ok, text},
          else: {:error, :source_content_too_large}

      true ->
        {:error, :source_fetch_empty}
    end
  end

  # Validation and lookups

  defp validate_kind(kind) when kind in ["file", "url"], do: :ok
  defp validate_kind(kind), do: {:error, {:unsupported_source_kind, kind}}

  defp validate_default_scope(nil), do: :ok
  defp validate_default_scope(scope), do: Scope.validate(scope)

  defp ensure_enabled do
    if Config.enabled?(), do: :ok, else: {:error, :brain_disabled}
  end

  defp fetch_source(source_id) do
    case Repo.get(Source, source_id) do
      %Source{} = source -> {:ok, source}
      nil -> {:error, :not_found}
    end
  end
end
