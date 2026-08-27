defmodule Ankole.Brain.Claims do
  @moduledoc """
  Claim write path: atomic Facts and calibratable Takes.

  Every write validates the scope, holder, weight grid, and content gates.
  Facts run semantic dedup inside the same parent container, holder, and
  audience scope; two Agents that learn the same shared fact through
  different channels merge at write time. Claim changes insert a new row and
  connect the old one with `superseded_by`; Take resolution updates in
  place, once.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Scope
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @fact_kinds ~w(event preference commitment belief fact)
  @notabilities ~w(high medium low)
  @resolution_qualities ~w(correct incorrect partial unresolvable)

  # GBrain semantic dedup: top cosine at or above this merges.
  @dedup_threshold 0.95
  @dedup_candidate_limit 5

  # Server-side content gates: prompt contracts do the semantics, these stop
  # mechanical garbage.
  @claim_max_chars 2_000

  # Internal terminal claims (extraction watermarks) use this provenance
  # prefix; every recall, BM25, and vector candidate path excludes it.
  @internal_provenance_prefix "ankole-brain-internal:"

  @extraction_complete "EXTRACTION_COMPLETE"
  @extraction_not_applicable "EXTRACTION_NOT_APPLICABLE"

  @type writer :: String.t() | :system

  @doc "Reserved provenance prefix of internal terminal claims."
  @spec internal_provenance_prefix() :: String.t()
  def internal_provenance_prefix, do: @internal_provenance_prefix

  @doc """
  Narrows a Claim query to current external facts: `claim_type` fact, not
  expired, not superseded, and provenance outside the internal prefix that
  extraction terminals use.
  """
  @spec current_external_facts(Ecto.Queryable.t()) :: Ecto.Query.t()
  def current_external_facts(query) do
    query
    |> where([claim], claim.claim_type == "fact")
    |> where([claim], is_nil(claim.expired_at) and is_nil(claim.superseded_by))
    |> where([claim], not like(claim.provenance, ^(@internal_provenance_prefix <> "%")))
  end

  @doc "Closed kind whitelist for facts."
  @spec fact_kinds() :: [String.t()]
  def fact_kinds, do: @fact_kinds

  @doc """
  Writes one Fact through the shared contract.

  Returns `{:ok, %{claim: claim, status: status}}` where status is
  `:inserted`, `:duplicate` (an equal current fact already exists), or
  `:superseded` (the new fact replaced a semantically equal one with
  different text). When no embedding model is available the write degrades:
  dedup is skipped and the row's vector state stays untried.
  """
  @spec write_fact(map(), writer(), keyword()) ::
          {:ok, %{claim: Claim.t(), status: atom()}} | {:error, term()}
  def write_fact(attrs, writer, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- validate_parent(attrs, repo),
         :ok <- validate_claim_text(attrs[:claim]),
         :ok <- validate_fact_kind(attrs[:kind]),
         :ok <- validate_notability(attrs[:notability]),
         :ok <- validate_grid_value(attrs[:confidence], :confidence),
         :ok <- validate_holder(attrs[:holder], repo),
         :ok <- validate_scope(attrs[:audience_scope], writer),
         :ok <- validate_required_provenance(attrs[:provenance]),
         :ok <- validate_valid_from(attrs[:valid_from]) do
      {embedding, signature} = resolve_embedding(attrs[:claim], opts)

      dedup? = Keyword.get(opts, :dedup, true)

      repo.transact(fn repo ->
        case find_dedup_action(repo, attrs, if(dedup?, do: embedding)) do
          {:duplicate, existing} ->
            {:ok, %{claim: existing, status: :duplicate}}

          {:supersede, existing} ->
            with {:ok, claim} <- insert_fact(repo, attrs, embedding, signature, writer, opts),
                 {:ok, _old} <- mark_superseded(repo, existing, claim.id) do
              {:ok, %{claim: claim, status: :superseded, superseded_claim_id: existing.id}}
            end

          :insert ->
            with {:ok, claim} <- insert_fact(repo, attrs, embedding, signature, writer, opts) do
              {:ok, %{claim: claim, status: :inserted}}
            end
        end
      end)
    end
  end

  @doc """
  Writes one Take through the shared contract. Takes keep GBrain's open kind
  string and never enter fact dedup.
  """
  @spec write_take(map(), writer(), keyword()) :: {:ok, Claim.t()} | {:error, term()}
  def write_take(attrs, writer, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- validate_parent(attrs, repo),
         :ok <- validate_claim_text(attrs[:claim]),
         :ok <- validate_open_kind(attrs[:kind]),
         :ok <- validate_grid_value(attrs[:weight], :weight),
         :ok <- validate_holder(attrs[:holder], repo),
         :ok <- validate_scope(attrs[:audience_scope], writer),
         :ok <- validate_required_provenance(attrs[:provenance]) do
      {embedding, signature} = resolve_embedding(attrs[:claim], opts)
      now = DateTime.utc_now(:microsecond)

      claim = %Claim{
        id: UUIDv7.autogenerate(),
        author_uid: author_uid(writer, opts),
        claim_type: "take",
        object_slug: attrs[:object_slug],
        signal_gateway_channel_id: attrs[:signal_gateway_channel_id],
        claim: attrs[:claim],
        kind: attrs[:kind],
        holder: attrs[:holder],
        audience_scope: attrs[:audience_scope],
        weight: attrs[:weight],
        since_date: attrs[:since_date],
        until_date: attrs[:until_date],
        active: true,
        provenance: attrs[:provenance],
        embedding: embedding,
        embedding_signature: signature,
        embedded_at: if(embedding, do: now)
      }

      repo.insert(claim)
    end
  end

  @doc """
  Supersedes one claim with a corrected row of the same claim type. The old
  row leaves the current state and keeps history through `superseded_by`.
  A superseded Take also becomes inactive.
  """
  @spec supersede_claim(Ecto.UUID.t(), map(), writer(), keyword()) ::
          {:ok, Claim.t()} | {:error, term()}
  def supersede_claim(claim_id, attrs, writer, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    # The replacement text is known before the transaction, so the embedding
    # network call runs before this function takes the row lock.
    prepared = prepare_embedding(attrs[:claim])

    repo.transact(fn repo ->
      with {:ok, old} <- lock_claim(repo, claim_id),
           :ok <- ensure_not_superseded(old),
           :ok <- validate_edit_eligibility(old, writer) do
        replacement =
          attrs
          |> Map.put_new(:kind, old.kind)
          |> Map.put_new(:holder, old.holder)
          |> Map.put_new(:audience_scope, old.audience_scope)
          |> Map.put_new(:provenance, old.provenance)
          |> Map.put(:object_slug, old.object_slug)
          |> Map.put(:signal_gateway_channel_id, old.signal_gateway_channel_id)

        result =
          case old.claim_type do
            "fact" ->
              replacement =
                replacement
                |> Map.put_new(:notability, old.notability)
                |> Map.put_new(:confidence, old.confidence)
                |> Map.put_new(:valid_from, old.valid_from)

              # An explicit correction replaces exactly this claim; dedup
              # would only rediscover the row it is replacing.
              with {:ok, %{claim: claim}} <-
                     write_fact(replacement, writer,
                       repo: repo,
                       dedup: false,
                       embedding: prepared
                     ) do
                {:ok, claim}
              end

            "take" ->
              replacement = Map.put_new(replacement, :weight, old.weight)
              write_take(replacement, writer, repo: repo, embedding: prepared)
          end

        with {:ok, claim} <- result,
             {:ok, _old} <- mark_superseded(repo, old, claim.id) do
          {:ok, claim}
        end
      end
    end)
  end

  @doc """
  Expires one current Fact out of the current state; history stays.
  """
  @spec expire_fact(Ecto.UUID.t(), keyword()) :: {:ok, Claim.t()} | {:error, term()}
  def expire_fact(claim_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transact(fn repo ->
      with {:ok, claim} <- lock_claim(repo, claim_id),
           :ok <- ensure_claim_type(claim, "fact") do
        claim
        |> Ecto.Changeset.change(expired_at: DateTime.utc_now(:microsecond))
        |> repo.update()
      end
    end)
  end

  @doc """
  Deactivates one Take; it leaves the current judgment set but keeps its
  calibration history.
  """
  @spec deactivate_take(Ecto.UUID.t(), keyword()) :: {:ok, Claim.t()} | {:error, term()}
  def deactivate_take(claim_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transact(fn repo ->
      with {:ok, claim} <- lock_claim(repo, claim_id),
           :ok <- ensure_claim_type(claim, "take") do
        claim
        |> Ecto.Changeset.change(active: false)
        |> repo.update()
      end
    end)
  end

  @doc """
  Expires every current fact one source learning session derived for one
  object. Source relearn calls this inside its commit transaction before it
  re-extracts, so the current claims always reflect the current source
  revision; expired rows keep the history.
  """
  @spec expire_source_session_facts(module(), String.t(), String.t()) :: non_neg_integer()
  def expire_source_session_facts(repo, object_slug, session) do
    now = DateTime.utc_now(:microsecond)

    {count, _rows} =
      Claim
      |> where([claim], claim.claim_type == "fact" and is_nil(claim.expired_at))
      |> where([claim], claim.object_slug == ^object_slug)
      |> where([claim], claim.provenance_session == ^session)
      |> repo.update_all(set: [expired_at: now, updated_at: now])

    count
  end

  @doc """
  Resolves one Take in place. Resolution is immutable: a second resolve
  returns `{:error, :already_resolved}`.
  """
  @spec resolve_take(Ecto.UUID.t(), map(), String.t(), keyword()) ::
          {:ok, Claim.t()} | {:error, term()}
  def resolve_take(claim_id, resolution, resolved_by, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transact(fn repo ->
      with {:ok, claim} <- lock_claim(repo, claim_id),
           :ok <- ensure_claim_type(claim, "take"),
           :ok <- ensure_unresolved(claim),
           :ok <- validate_resolution(resolution) do
        claim
        |> Ecto.Changeset.change(
          resolved_at: DateTime.utc_now(:microsecond),
          resolved_quality: resolution[:resolved_quality],
          resolved_outcome: resolution[:resolved_outcome],
          resolved_value: resolution[:resolved_value],
          resolved_unit: resolution[:resolved_unit],
          resolution_provenance: resolution[:resolution_provenance],
          resolved_by: resolved_by,
          active: false
        )
        |> repo.update()
      end
    end)
  end

  @doc """
  Writes the internal terminal claim for one extraction slice. The claim is
  channel-parented, low notability, and uses the reserved provenance prefix
  so it never enters recall; `provenance_session` carries the slice version
  token that makes reruns idempotent.

  `boundary` is the `(first_seen_at, source_entry_id)` of the last covered
  entry in slice order: `valid_from` stores the arrival time and `context`
  the entry id, and together they are the next slice's watermark. A unique
  index on `(channel, provenance_session)` for internal terminals makes a
  concurrent rerun of the same slice fail its commit instead of
  double-writing memory.
  """
  @spec write_extraction_terminal(String.t(), String.t(), :complete | :not_applicable, keyword()) ::
          {:ok, Claim.t()} | {:error, term()}
  def write_extraction_terminal(channel_id, version_token, outcome, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    {boundary_at, boundary_entry_id} = Keyword.fetch!(opts, :boundary)

    text =
      case outcome do
        :complete -> @extraction_complete
        :not_applicable -> @extraction_not_applicable
      end

    claim = %Claim{
      id: UUIDv7.autogenerate(),
      claim_type: "fact",
      signal_gateway_channel_id: channel_id,
      claim: text,
      kind: "event",
      holder: "brain",
      audience_scope: "world",
      notability: "low",
      confidence: 1.0,
      valid_from: usec(boundary_at),
      context: boundary_entry_id,
      provenance: @internal_provenance_prefix <> "extraction",
      provenance_session: version_token
    }

    repo.insert(claim)
  end

  @doc """
  Returns the terminal claim of one slice version token, when present.
  """
  @spec extraction_terminal(String.t(), String.t(), keyword()) :: Claim.t() | nil
  def extraction_terminal(channel_id, version_token, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    Claim
    |> where([claim], claim.signal_gateway_channel_id == ^channel_id)
    |> where([claim], claim.provenance_session == ^version_token)
    |> where([claim], like(claim.provenance, ^(@internal_provenance_prefix <> "%")))
    |> where([claim], is_nil(claim.expired_at))
    |> limit(1)
    |> repo.one()
  end

  @doc """
  Validates that a weight or confidence value sits on the 0.05 grid inside
  0..1. The grid rejects false precision from model output.
  """
  @spec validate_grid_value(term(), atom()) :: :ok | {:error, term()}
  def validate_grid_value(value, field) when is_number(value) do
    scaled = value * 20

    cond do
      value < 0.0 or value > 1.0 -> {:error, {:out_of_range, field}}
      abs(scaled - round(scaled)) > 1.0e-9 -> {:error, {:off_weight_grid, field}}
      true -> :ok
    end
  end

  def validate_grid_value(_value, field), do: {:error, {:missing_number, field}}

  @doc """
  Snaps a model-produced number onto the 0.05 grid inside 0..1.

  Batch learning paths use this instead of rejecting: a rejected item is
  lost forever, while the tool path keeps strict `validate_grid_value/2`
  rejection. A non-number becomes the neutral 0.5.
  """
  @spec snap_to_grid(term()) :: float()
  def snap_to_grid(value) when is_number(value) do
    value
    |> min(1.0)
    |> max(0.0)
    |> then(fn value -> Float.round(value * 20) / 20 end)
  end

  def snap_to_grid(_value), do: 0.5

  # Embedding preparation and dedup

  @doc """
  Prepares one claim text's embedding outside any transaction. The
  `{vector, signature}` pair feeds `write_fact/3` and `write_take/3` through
  the `embedding:` option; a failure returns `{nil, nil}`, the degraded
  untried vector state that skips dedup and leaves the rest to Self-healing.
  """
  @spec prepare_embedding(term()) :: {Pgvector.t() | nil, String.t() | nil}
  def prepare_embedding(text) when is_binary(text) do
    case Embeddings.embed_texts([text]) do
      {:ok, [vector]} ->
        case Embeddings.signature() do
          {:ok, signature} -> {vector, signature}
          {:error, _reason} -> {nil, nil}
        end

      {:error, _reason} ->
        {nil, nil}
    end
  end

  def prepare_embedding(_text), do: {nil, nil}

  # Callers that hold a transaction or a row lock prepare the embedding
  # first and pass `embedding: {vector, signature}`, so the final commit
  # stays free of network I/O. `embed: false` (source learning) defers the
  # vector to Self-healing entirely and skips dedup, because a nil embedding
  # has nothing to compare. The default embeds here, which runs before any
  # transaction this module opens.
  defp resolve_embedding(text, opts) do
    case Keyword.fetch(opts, :embedding) do
      {:ok, {vector, signature}} ->
        {vector, signature}

      :error ->
        if Keyword.get(opts, :embed, true), do: prepare_embedding(text), else: {nil, nil}
    end
  end

  defp find_dedup_action(_repo, _attrs, nil), do: :insert

  defp find_dedup_action(repo, attrs, embedding) do
    candidates =
      Claim
      |> current_external_facts()
      |> where([claim], claim.holder == ^attrs[:holder])
      |> where([claim], claim.audience_scope == ^attrs[:audience_scope])
      |> where([claim], not is_nil(claim.embedding))
      |> parent_filter(attrs)
      |> order_by([claim], fragment("? <=> ?", claim.embedding, ^embedding))
      |> limit(@dedup_candidate_limit)
      |> select([claim], {claim, fragment("1 - (? <=> ?)", claim.embedding, ^embedding)})
      |> repo.all()

    case candidates do
      [{top, similarity} | _rest] when similarity >= @dedup_threshold ->
        cond do
          normalized_text(top.claim) == normalized_text(attrs[:claim]) -> {:duplicate, top}
          top.kind == attrs[:kind] -> {:supersede, top}
          true -> {:duplicate, top}
        end

      _no_hit ->
        :insert
    end
  end

  defp parent_filter(query, %{object_slug: slug}) when is_binary(slug),
    do: where(query, [claim], claim.object_slug == ^slug)

  defp parent_filter(query, %{signal_gateway_channel_id: channel_id})
       when is_binary(channel_id),
       do: where(query, [claim], claim.signal_gateway_channel_id == ^channel_id)

  defp normalized_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp insert_fact(repo, attrs, embedding, signature, writer, opts) do
    now = DateTime.utc_now(:microsecond)

    claim = %Claim{
      id: UUIDv7.autogenerate(),
      author_uid: author_uid(writer, opts),
      claim_type: "fact",
      object_slug: attrs[:object_slug],
      signal_gateway_channel_id: attrs[:signal_gateway_channel_id],
      claim: attrs[:claim],
      kind: attrs[:kind],
      holder: attrs[:holder],
      audience_scope: attrs[:audience_scope],
      notability: attrs[:notability],
      context: attrs[:context],
      valid_from: usec(attrs[:valid_from]),
      valid_until: usec(attrs[:valid_until]),
      confidence: attrs[:confidence],
      provenance_session: attrs[:provenance_session],
      provenance: attrs[:provenance],
      embedding: embedding,
      embedding_signature: signature,
      embedded_at: if(embedding, do: now)
    }

    repo.insert(claim)
  end

  # Model-produced ISO 8601 datetimes often carry second precision, while
  # the `:utc_datetime_usec` columns require microsecond precision on a raw
  # struct insert. Normalizing here keeps every valid DateTime insertable.
  defp usec(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp usec(other), do: other

  defp mark_superseded(repo, %Claim{} = old, new_claim_id) do
    changes =
      case old.claim_type do
        "fact" ->
          [superseded_by: new_claim_id, expired_at: DateTime.utc_now(:microsecond)]

        "take" ->
          [superseded_by: new_claim_id, active: false]
      end

    old
    |> Ecto.Changeset.change(changes)
    |> repo.update()
  end

  # Validation

  defp validate_parent(attrs, repo) do
    object_slug = attrs[:object_slug]
    channel_id = attrs[:signal_gateway_channel_id]

    cond do
      is_binary(object_slug) and is_nil(channel_id) ->
        case Objects.get_by_slug(object_slug, repo: repo) do
          {:ok, _object} -> :ok
          {:error, :not_found} -> {:error, {:unknown_parent_object, object_slug}}
        end

      is_binary(channel_id) and is_nil(object_slug) ->
        :ok

      true ->
        {:error, :claim_parent_required}
    end
  end

  defp validate_claim_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :blank_claim}
      String.length(trimmed) > @claim_max_chars -> {:error, {:claim_too_long, @claim_max_chars}}
      not String.valid?(trimmed) -> {:error, :claim_not_text}
      String.contains?(trimmed, <<0>>) -> {:error, :claim_not_text}
      garbled?(trimmed) -> {:error, :claim_garbled}
      true -> :ok
    end
  end

  defp validate_claim_text(_text), do: {:error, :blank_claim}

  # Mechanical junk gate: overwhelming single-character repetition or a body
  # that is mostly non-printable is not a memory.
  defp garbled?(text) do
    graphemes = String.graphemes(text)
    total = length(graphemes)

    if total < 16 do
      false
    else
      {_top_char, top_count} =
        graphemes
        |> Enum.frequencies()
        |> Enum.max_by(fn {_grapheme, count} -> count end)

      printable_count = Enum.count(graphemes, &String.match?(&1, ~r/[[:print:]\p{L}\p{N}]/u))

      top_count / total > 0.6 or printable_count / total < 0.5
    end
  end

  defp validate_fact_kind(kind) when kind in @fact_kinds, do: :ok
  defp validate_fact_kind(kind), do: {:error, {:invalid_fact_kind, kind, @fact_kinds}}

  defp validate_open_kind(kind) when is_binary(kind) do
    if String.trim(kind) == "", do: {:error, :blank_kind}, else: :ok
  end

  defp validate_open_kind(_kind), do: {:error, :blank_kind}

  defp validate_notability(notability) when notability in @notabilities, do: :ok

  defp validate_notability(notability),
    do: {:error, {:invalid_notability, notability, @notabilities}}

  defp validate_holder(holder, repo) when is_binary(holder) and holder != "" do
    if Objects.valid_holder?(holder, repo: repo),
      do: :ok,
      else: {:error, {:unresolvable_holder, holder}}
  end

  defp validate_holder(_holder, _repo), do: {:error, :missing_holder}

  defp validate_scope(scope, :system), do: Scope.validate(scope)

  defp validate_scope(scope, writer_uid) when is_binary(writer_uid),
    do: Scope.validate_writable(scope, writer_uid)

  defp validate_required_provenance(provenance)
       when is_binary(provenance) and provenance != "" do
    if String.starts_with?(provenance, @internal_provenance_prefix),
      do: {:error, :reserved_provenance_prefix},
      else: :ok
  end

  defp validate_required_provenance(_provenance), do: {:error, :missing_provenance}

  defp validate_valid_from(%DateTime{}), do: :ok
  defp validate_valid_from(_value), do: {:error, :missing_valid_from}

  defp validate_resolution(resolution) do
    quality = resolution[:resolved_quality]
    outcome = resolution[:resolved_outcome]

    cond do
      quality not in @resolution_qualities ->
        {:error, {:invalid_resolution_quality, quality}}

      quality in ["correct", "incorrect"] and not is_boolean(outcome) ->
        {:error, :resolution_outcome_required}

      quality in ["partial", "unresolvable"] and not is_nil(outcome) ->
        {:error, :resolution_outcome_forbidden}

      true ->
        :ok
    end
  end

  defp validate_edit_eligibility(%Claim{} = claim, writer) do
    case writer do
      :system ->
        :ok

      writer_uid when is_binary(writer_uid) ->
        if Scope.satisfied_by?(claim.audience_scope, writer_uid) or
             claim.author_uid == writer_uid,
           do: :ok,
           else: {:error, :writer_not_in_claim_scope}
    end
  end

  defp ensure_not_superseded(%Claim{superseded_by: nil}), do: :ok
  defp ensure_not_superseded(%Claim{}), do: {:error, :already_superseded}

  defp ensure_claim_type(%Claim{claim_type: type}, type), do: :ok

  defp ensure_claim_type(%Claim{claim_type: actual}, expected),
    do: {:error, {:wrong_claim_type, actual, expected}}

  defp ensure_unresolved(%Claim{resolved_at: nil}), do: :ok
  defp ensure_unresolved(%Claim{}), do: {:error, :already_resolved}

  defp lock_claim(repo, claim_id) do
    Claim
    |> where([claim], claim.id == ^claim_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Claim{} = claim -> {:ok, claim}
      nil -> {:error, :not_found}
    end
  end

  defp author_uid(:system, opts), do: Keyword.get(opts, :author_uid)
  defp author_uid(writer, _opts) when is_binary(writer), do: writer
end
