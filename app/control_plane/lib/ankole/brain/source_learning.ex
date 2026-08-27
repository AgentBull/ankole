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

  `url` Sources fetch through the AIGateway web-fetch provider configured
  in `brain.web_fetch_model`, which extracts readable text; a raw HTTP body
  would put HTML markup into chunks and claims. `file` Sources accept
  UTF-8 text only and reject binary content loudly.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Repo

  @max_content_bytes 10 * 1024 * 1024
  @extraction_window_chars 12_000

  @doc """
  Registers one file or url Source.
  """
  @spec register_source(map()) :: {:ok, Source.t()} | {:error, term()}
  def register_source(attrs) when is_map(attrs) do
    with :ok <- validate_kind(attrs[:kind]),
         :ok <- validate_default_scope(attrs[:default_audience_scope]) do
      %Source{id: UUIDv7.autogenerate()}
      |> Source.changeset(%{
        upstream_id: attrs[:upstream_id],
        kind: attrs[:kind],
        name: attrs[:name],
        default_audience_scope: attrs[:default_audience_scope] || "world",
        config: attrs[:config] || %{}
      })
      |> Repo.insert()
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
         :ok <- ensure_not_archived(source),
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
         :ok <- ensure_not_archived(source),
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
      body: scoped_body(content, scope)
    }

    # Model extraction is the slow, fallible part and must not hold locks;
    # any failed window aborts the run with no state change.
    with {:ok, extraction} <- extract_items(slug, source.name, content) do
      commit_run(source, object_attrs, extraction, scope, fingerprint)
    end
  end

  defp scoped_body(content, "world"), do: content

  defp scoped_body(content, scope),
    do: ~s({% audience scope="#{scope}" %}\n) <> content <> "\n{% /audience %}"

  # One transaction owns every write of the run. The locked re-read fences
  # two races: an archive during the fetch or extraction (the archived
  # Source must not gain new memory), and a revision that advanced since
  # this run read it (the later content must not be overwritten by the
  # earlier run's late commit).
  defp commit_run(source, object_attrs, extraction, scope, fingerprint) do
    session = provenance_session(source)

    result =
      Repo.transact(fn repo ->
        with {:ok, current} <- lock_source(repo, source.id),
             :ok <- ensure_not_archived(current),
             :ok <- ensure_same_revision(current, source.upstream_revision),
             {:ok, object} <- upsert_object(repo, object_attrs),
             expired = Claims.expire_source_session_facts(repo, object.slug, session),
             {:ok, written} <- write_claims(repo, object, extraction.items, scope, session),
             {:ok, _source} <- advance_revision(repo, current, fingerprint) do
          {:ok,
           %{
             status: :learned,
             object_slug: object.slug,
             windows: extraction.windows,
             claims: written.claims,
             claims_expired: expired,
             rejected: written.rejected
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

  defp lock_source(repo, source_id) do
    Source
    |> where([source], source.id == ^source_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Source{} = source -> {:ok, source}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_same_revision(%Source{upstream_revision: current}, expected)
       when current == expected,
       do: :ok

  defp ensure_same_revision(%Source{}, _expected), do: {:error, :stale_run}

  defp upsert_object(repo, attrs) do
    case Objects.get_by_slug(attrs.slug, repo: repo) do
      {:ok, object} ->
        Objects.update_object(
          attrs.slug,
          %{body: attrs.body, title: attrs.title, expected_content_hash: object.content_hash},
          :system,
          repo: repo
        )

      {:error, :not_found} ->
        Objects.create_object(
          %{
            slug: attrs.slug,
            type: "media",
            subtype: attrs.subtype,
            title: attrs.title,
            body: attrs.body
          },
          :system,
          repo: repo
        )
    end
  end

  defp advance_revision(repo, %Source{} = source, fingerprint) do
    source
    |> Source.changeset(%{
      upstream_revision: fingerprint,
      last_sync_at: DateTime.utc_now(:microsecond)
    })
    |> repo.update()
  end

  # ── Extraction ──────────────────────────────────────────────────

  # Extraction covers every window of the content when the object type is
  # extractable. A model failure aborts the run instead of counting as an
  # empty result: recording `learned` with zero claims would freeze the
  # fingerprint and skip the content forever.
  defp extract_items(slug, title, content) do
    cond do
      not extractable_type?(slug) ->
        {:ok, %{windows: 0, items: []}}

      Config.extraction_model() == nil ->
        {:error, :extraction_model_not_configured}

      true ->
        model = Config.extraction_model()

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
      {:ok, _no_items} -> {:ok, []}
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

  # ── Content fetch ───────────────────────────────────────────────

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
    with {:ok, model} <- web_fetch_model() do
      selector = model["provider_id"] <> "/" <> model["model"]

      case AIGateway.create_web_fetch(
             Embeddings.subject_uid(),
             %{"model" => selector, "urls" => [url]}
           ) do
        {:ok, %{body: %{"results" => [result | _rest]}}} -> web_fetch_text(result)
        {:ok, _response} -> {:error, :source_fetch_empty}
        {:error, reason} -> {:error, {:source_fetch_failed, reason}}
      end
    end
  end

  defp fetch_content(%Source{kind: kind}), do: {:error, {:unsupported_source_kind, kind}}

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

  defp web_fetch_model do
    case Config.web_fetch_model() do
      nil -> {:error, :web_fetch_model_not_configured}
      model -> {:ok, model}
    end
  end

  # ── Validation and lookups ──────────────────────────────────────

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

  defp ensure_not_archived(%Source{archived_at: nil}), do: :ok
  defp ensure_not_archived(%Source{}), do: {:error, :source_archived}
end
