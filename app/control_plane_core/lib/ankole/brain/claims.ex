defmodule Ankole.Brain.Claims do
  @moduledoc """
  Claim write path: atomic Facts and calibratable Takes.

  Every write validates the scope, holder, weight grid, and content gates.
  Facts run semantic dedup inside the same parent container, holder, and
  audience scope; two Agents that learn the same shared fact through
  different channels merge at write time. Claim changes insert a new row and
  connect the old one with `superseded_by`; Take resolution updates in
  place, once.

  A generic action on `Ankole.Brain.Schemas.Claim` owns the transaction of
  each write. The `_in_tx` functions give the steps of these actions; another
  action calls them in its own transaction. The semantic dedup query and the
  Ecto filters of the retrieval queries stay Ecto queries (M9 retrieval).
  """

  import Ecto.Query, warn: false
  require Ash.Query

  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Scope
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

  @type writer :: String.t() | :system

  @doc """
  Keeps claims attached to a live Object or a signal channel. A missing Object
  row and a soft-deleted Object both make an Object-parented claim unavailable;
  a channel-parented claim has no Object slug and stays available.

  This is the Ecto form of the `live_parent?` calculation for the retrieval
  queries.
  """
  @spec filter_live_parents(Ecto.Queryable.t()) :: Ecto.Query.t()
  def filter_live_parents(query) do
    query
    |> join(:left, [claim], object in Object,
      as: :claim_parent_object,
      on: object.tenant_id == claim.tenant_id and object.slug == claim.object_slug
    )
    |> where(
      [claim, claim_parent_object: object],
      is_nil(claim.object_slug) or
        (not is_nil(object.slug) and is_nil(object.deleted_at))
    )
  end

  @doc """
  Narrows a Claim query to current external facts: `claim_type` fact, not
  expired, not superseded, and attached to a live Object or a signal channel.
  """
  @spec current_external_facts(Ecto.Queryable.t()) :: Ecto.Query.t()
  def current_external_facts(query) do
    query
    |> filter_live_parents()
    |> where([claim], claim.claim_type == :fact)
    |> where([claim], is_nil(claim.expired_at) and is_nil(claim.superseded_by))
  end

  @doc "Closed kind whitelist for facts."
  @spec fact_kinds() :: [String.t()]
  def fact_kinds, do: @fact_kinds

  @doc "Lists Claims for the Console read model."
  @spec list_for_console(keyword()) :: [Claim.t()]
  def list_for_console(opts) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    Claim
    |> maybe_console_object(Keyword.get(opts, :object_slug))
    |> maybe_console_type(Keyword.get(opts, :claim_type))
    |> maybe_console_status(Keyword.get(opts, :status))
    |> maybe_console_search(Keyword.get(opts, :search))
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
  end

  @doc "Lists Claims related to one Principal for the Console audit read model."
  @spec list_for_principal_audit(String.t(), keyword()) :: [Claim.t()]
  def list_for_principal_audit(principal_uid, opts)
      when is_binary(principal_uid) and is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    holder_slugs = [
      Scope.principal_page_slug(:human, principal_uid),
      Scope.principal_page_slug(:agent, principal_uid)
    ]

    scope = "principal:#{principal_uid}"

    principal_ref =
      Ankole.ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: principal_uid})

    Claim
    |> Ash.Query.filter(
      holder in ^holder_slugs or author == ^principal_ref or audience_scope == ^scope
    )
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
  end

  @doc """
  Writes one Fact through the shared contract.

  Transitional: callers outside the Brain directory move to
  `Ankole.Brain.write_fact/2`, and Brain modules use `write_fact_in_tx/3` or
  the `:write_fact` action.
  """
  @spec write_fact(map(), writer(), keyword()) ::
          {:ok, %{claim: Claim.t(), status: atom()}} | {:error, term()}
  def write_fact(attrs, writer, opts \\ []),
    do: Ankole.Ash.run_action(Claim, :write_fact, %{attrs: attrs, writer: writer, options: opts})

  @doc """
  Writes one Fact in the caller's transaction.

  Returns `{:ok, %{claim: claim, status: status}}` where status is
  `:inserted`, `:duplicate` (an equal current fact already exists), or
  `:superseded` (the new fact replaced a semantically equal one with
  different text). When no embedding model is available the write degrades:
  dedup is skipped and the row's vector state stays untried. A caller in a
  transaction gives `embedding:` or `embed: false`, so the transaction does
  no network I/O.
  """
  @spec write_fact_in_tx(map(), writer(), keyword()) ::
          {:ok, %{claim: Claim.t(), status: atom()}} | {:error, term()}
  def write_fact_in_tx(attrs, writer, opts \\ []) when is_map(attrs) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, embedding} <- prepare_fact(attrs, writer, opts) do
      record_fact_in_tx(attrs, writer, embedding, opts)
    end
  end

  @doc false
  # Validates a Fact and gets its embedding before the transaction of the
  # `:write_fact` action starts.
  def prepare_fact_input(%Ash.ActionInput{arguments: args} = input) do
    case prepare_fact(args.attrs, args.writer, args.options) do
      {:ok, embedding} -> Ash.ActionInput.set_private_argument(input, :embedding, embedding)
      {:error, _reason} = error -> Ankole.Errors.wrap(error)
    end
  end

  defp prepare_fact(attrs, writer, opts) when is_map(attrs) do
    with :ok <- validate_parent(attrs),
         :ok <- validate_claim_text(attrs[:claim]),
         :ok <- validate_fact_kind(attrs[:kind]),
         :ok <- validate_notability(attrs[:notability]),
         :ok <- validate_grid_value(attrs[:confidence], :confidence),
         :ok <- validate_holder(attrs[:holder]),
         :ok <- validate_scope(attrs[:audience_scope], writer),
         :ok <- validate_required_provenance(attrs[:provenance]),
         :ok <- validate_valid_from(attrs[:valid_from]) do
      {:ok, resolve_embedding(attrs[:claim], opts)}
    end
  end

  @doc false
  # Runs the semantic dedup and the insert of a validated Fact in the caller's
  # transaction.
  def record_fact_in_tx(attrs, writer, {embedding, signature}, opts) do
    dedup? = Keyword.get(opts, :dedup, true)

    case find_dedup_action(Repo, attrs, if(dedup?, do: {embedding, signature})) do
      {:duplicate, existing} ->
        {:ok, %{claim: existing, status: :duplicate}}

      {:supersede, existing} ->
        with {:ok, claim} <- insert_fact(attrs, embedding, signature, writer, opts),
             {:ok, _old} <- mark_superseded(existing, claim.id) do
          {:ok, %{claim: claim, status: :superseded, superseded_claim_id: existing.id}}
        end

      :insert ->
        with {:ok, claim} <- insert_fact(attrs, embedding, signature, writer, opts) do
          {:ok, %{claim: claim, status: :inserted}}
        end
    end
  end

  @doc """
  Writes one Take through the shared contract. Takes keep GBrain's open kind
  string and never enter fact dedup.
  """
  @spec write_take(map(), writer(), keyword()) :: {:ok, Claim.t()} | {:error, term()}
  def write_take(attrs, writer, opts \\ []) when is_map(attrs) do
    with :ok <- validate_parent(attrs),
         :ok <- validate_claim_text(attrs[:claim]),
         :ok <- validate_open_kind(attrs[:kind]),
         :ok <- validate_grid_value(attrs[:weight], :weight),
         :ok <- validate_holder(attrs[:holder]),
         :ok <- validate_scope(attrs[:audience_scope], writer),
         :ok <- validate_required_provenance(attrs[:provenance]),
         {:ok, until_date} <- cast_until_date(attrs[:until_date]) do
      {embedding, signature} = resolve_embedding(attrs[:claim], opts)
      now = DateTime.utc_now(:microsecond)

      attrs = %{
        author: Ankole.ActorRef.from_writer(writer, Repo.tenant_id!(), opts),
        provenance_session: attrs[:provenance_session],
        object_slug: attrs[:object_slug],
        conversation_id: attrs[:conversation_id],
        claim: attrs[:claim],
        kind: attrs[:kind],
        holder: attrs[:holder],
        audience_scope: attrs[:audience_scope],
        weight: attrs[:weight] * 1.0,
        since_date: attrs[:since_date],
        until_date: until_date,
        provenance: attrs[:provenance],
        embedding: embedding,
        embedding_signature: signature,
        embedded_at: if(embedding, do: now)
      }

      Ankole.Ash.create(Claim, :record_take, attrs)
    end
  end

  # `until_date` gates the Take into Dreaming's due-date grading, so a value
  # that is not one calendar date is rejected here, for every writer.
  defp cast_until_date(nil), do: {:ok, nil}
  defp cast_until_date(%Date{} = date), do: {:ok, date}

  defp cast_until_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_until_date}
    end
  end

  defp cast_until_date(_value), do: {:error, :invalid_until_date}

  @doc """
  Supersedes one claim with a corrected row of the same claim type, in the
  caller's transaction. The old row leaves the current state and keeps
  history through `superseded_by`. A superseded Take also becomes inactive.
  `embedding:` gives the prepared embedding of the replacement text, and
  `author:` names the audit identity of a `:system` writer.
  """
  @spec supersede_claim_in_tx(Ecto.UUID.t(), map(), writer(), keyword()) ::
          {:ok, Claim.t()} | {:error, term()}
  def supersede_claim_in_tx(claim_id, attrs, writer, opts) do
    prepared = Keyword.fetch!(opts, :embedding)

    with :ok <- Repo.require_transaction(Repo),
         {:ok, old} <- lock_claim(claim_id),
         :ok <- ensure_not_superseded(old),
         :ok <- validate_edit_eligibility(old, writer) do
      replacement =
        attrs
        |> Map.put_new(:kind, old.kind)
        |> Map.put_new(:holder, old.holder)
        |> Map.put_new(:audience_scope, old.audience_scope)
        |> Map.put_new(:provenance, old.provenance)
        |> Map.put(:object_slug, old.object_slug)
        |> Map.put(:conversation_id, old.conversation_id)

      result =
        case old.claim_type do
          :fact ->
            replacement =
              replacement
              |> Map.put_new(:notability, old.notability)
              |> Map.put_new(:confidence, old.confidence)
              |> Map.put_new(:valid_from, old.valid_from)

            # An explicit correction replaces exactly this claim; dedup
            # would only rediscover the row it is replacing.
            with {:ok, %{claim: claim}} <-
                   write_fact_in_tx(replacement, writer,
                     dedup: false,
                     embedding: prepared,
                     author: Keyword.get(opts, :author)
                   ) do
              {:ok, claim}
            end

          :take ->
            replacement = Map.put_new(replacement, :weight, old.weight)

            write_take(replacement, writer,
              embedding: prepared,
              author: Keyword.get(opts, :author)
            )
        end

      with {:ok, claim} <- result,
           {:ok, _old} <- mark_superseded(old, claim.id) do
        {:ok, claim}
      end
    end
  end

  @doc false
  # The replacement text is known before the transaction of the
  # `:supersede_claim` action, so the embedding network call runs before the
  # action takes the row lock.
  def prepare_replacement_input(%Ash.ActionInput{arguments: args} = input) do
    Ash.ActionInput.set_private_argument(
      input,
      :embedding,
      prepare_embedding(args.attrs[:claim])
    )
  end

  @doc """
  Expires one current Fact out of the current state in the caller's
  transaction; history stays.
  """
  @spec expire_fact_in_tx(Ecto.UUID.t()) :: {:ok, Claim.t()} | {:error, term()}
  def expire_fact_in_tx(claim_id) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, claim} <- lock_claim(claim_id),
         :ok <- ensure_claim_type(claim, :fact) do
      Ankole.Ash.update(claim, :expire_fact, %{at: DateTime.utc_now(:microsecond)})
    end
  end

  @doc """
  Deactivates one Take in the caller's transaction; it leaves the current
  judgment set but keeps its calibration history.
  """
  @spec deactivate_take_in_tx(Ecto.UUID.t()) :: {:ok, Claim.t()} | {:error, term()}
  def deactivate_take_in_tx(claim_id) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, claim} <- lock_claim(claim_id),
         :ok <- ensure_claim_type(claim, :take) do
      Ankole.Ash.update(claim, :deactivate_take, %{})
    end
  end

  @doc """
  Expires every current fact one source learning session derived for one
  object. Source relearn calls this inside its commit transaction before it
  re-extracts, so the current claims always reflect the current source
  revision; expired rows keep the history.
  """
  @spec expire_source_session_facts(module(), String.t(), String.t()) :: non_neg_integer()
  def expire_source_session_facts(_repo, object_slug, session) do
    Claim
    |> Ash.Query.filter(claim_type == :fact and is_nil(expired_at))
    |> Ash.Query.filter(object_slug == ^object_slug and provenance_session == ^session)
    |> update_claims_in_tx(:expire_fact, %{at: DateTime.utc_now(:microsecond)})
  end

  @doc "Withdraws the current claims derived by one changed conversation Source."
  def withdraw_source_claims_in_tx(_repo, source_id, now) do
    session = "source:" <> source_id

    Claim
    |> Ash.Query.filter(
      provenance_session == ^session and claim_type == :fact and is_nil(expired_at)
    )
    |> update_claims_in_tx(:expire_fact, %{at: now})

    Claim
    |> Ash.Query.filter(provenance_session == ^session and claim_type == :take and active == true)
    |> update_claims_in_tx(:deactivate_take, %{at: now})

    :ok
  end

  @doc """
  Writes one consolidation Take and marks its source Facts in the caller's
  transaction. A crash between the two writes would leave unmarked Facts that
  promote a duplicate Take on the next round.
  """
  @spec consolidate_facts_in_tx(map(), [Ecto.UUID.t()], {Pgvector.t() | nil, String.t() | nil}) ::
          {:ok, Claim.t()} | {:error, term()}
  def consolidate_facts_in_tx(take_attrs, fact_ids, embedding) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, take} <- write_take(take_attrs, :system, embedding: embedding) do
      Claim
      |> Ash.Query.filter(id in ^fact_ids)
      |> update_claims_in_tx(:consolidate, %{
        consolidated_at: DateTime.utc_now(:microsecond),
        consolidated_into: take.id
      })

      {:ok, take}
    end
  end

  @doc false
  def repoint_in_tx(duplicate, canonical) do
    claims =
      Claim
      |> Ash.Query.filter(object_slug == ^duplicate)
      |> update_claims_in_tx(:reparent, %{object_slug: canonical})

    holders =
      Claim
      |> Ash.Query.filter(holder == ^duplicate)
      |> update_claims_in_tx(:reassign_holder, %{holder: canonical})

    {claims, holders}
  end

  # A failed set write rolls back the caller's transaction: the rows of one
  # source session or one merge change together or not at all.
  defp update_claims_in_tx(query, action, attrs) do
    case Ankole.Ash.update_where(query, action, attrs, select: [:id]) do
      {:ok, records} -> length(records)
      {:error, error} -> Repo.rollback(error)
    end
  end

  @doc """
  Resolves one Take in place, in the caller's transaction. Resolution is
  immutable: a second resolve returns `{:error, :already_resolved}`.
  """
  @spec resolve_take_in_tx(Ecto.UUID.t(), map(), String.t()) ::
          {:ok, Claim.t()} | {:error, term()}
  def resolve_take_in_tx(claim_id, resolution, resolved_by) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, claim} <- lock_claim(claim_id),
         :ok <- ensure_claim_type(claim, :take),
         :ok <- ensure_unresolved(claim),
         :ok <- validate_resolution(resolution) do
      Ankole.Ash.update(claim, :resolve_take, %{
        resolved_quality: resolution[:resolved_quality],
        resolved_outcome: resolution[:resolved_outcome],
        resolved_value: resolution[:resolved_value],
        resolved_unit: resolution[:resolved_unit],
        resolution_provenance: resolution[:resolution_provenance],
        resolved_by: resolved_by
      })
    end
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

  @doc """
  Prepares one claim text's embedding outside any transaction. The
  `{vector, signature}` pair feeds `write_fact_in_tx/3` and `write_take/3`
  through the `embedding:` option; a failure returns `{nil, nil}`, the degraded
  untried vector state that skips dedup and leaves the rest to Self-healing.
  """
  @spec prepare_embedding(term()) :: {Pgvector.t() | nil, String.t() | nil}
  def prepare_embedding(text) when is_binary(text) do
    case Embeddings.embed_texts([text]) do
      {:ok, {[vector], signature}} ->
        {vector, signature}

      {:error, _reason} ->
        {nil, nil}
    end
  end

  def prepare_embedding(_text), do: {nil, nil}

  @doc """
  Attaches a rebuilt Claim embedding in the caller's transaction and applies
  the normal fact dedup rule.

  A Fact written while embeddings were unavailable already exists before its
  first vector arrives. This operation makes that late vector follow the same
  ordering and dedup semantics as a successful write instead of leaving a
  second current Fact.
  """
  @spec attach_embedding_in_tx(Claim.t(), Pgvector.t(), String.t(), DateTime.t()) ::
          {:ok, :embedded | :deduplicated | :superseded | :stale} | {:error, term()}
  def attach_embedding_in_tx(%Claim{} = claim, embedding, signature, now)
      when is_binary(signature) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, current} <- lock_claim(claim.id) do
      attach_current_embedding(current, embedding, signature, now)
    end
  end

  @doc "Discards a failed embedding result when another attempt already changed the vector state."
  def record_embedding_error(%Claim{} = claim, error, signature) do
    Claim
    |> Ash.Query.filter(id == ^claim.id)
    |> Ankole.Ash.update_where(
      :record_embedding,
      %{
        embedding: nil,
        embedding_signature: signature,
        embedding_error: error,
        embedded_at: nil,
        input_embedded_at: claim.embedded_at,
        input_signature: claim.embedding_signature
      },
      select: [:id]
    )
    |> case do
      {:ok, []} -> {:ok, :stale}
      {:ok, [_claim]} -> {:ok, :updated}
      {:error, _error} = error -> error
    end
  end

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
  defp find_dedup_action(_repo, _attrs, {nil, _signature}), do: :insert
  defp find_dedup_action(_repo, _attrs, {_embedding, nil}), do: :insert

  defp find_dedup_action(repo, attrs, {embedding, signature}) do
    candidates =
      Claim
      |> current_external_facts()
      |> where([claim], claim.holder == ^attrs[:holder])
      |> where([claim], claim.audience_scope == ^attrs[:audience_scope])
      |> where([claim], not is_nil(claim.embedding))
      |> where([claim], claim.embedding_signature == ^signature)
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

  defp attach_current_embedding(
         %Claim{embedding_signature: signature, embedded_at: %DateTime{}},
         _embedding,
         signature,
         _now
       ),
       do: {:ok, :stale}

  defp attach_current_embedding(
         %Claim{claim_type: :fact, expired_at: nil, superseded_by: nil} = claim,
         embedding,
         signature,
         now
       ) do
    attrs = %{
      object_slug: claim.object_slug,
      conversation_id: claim.conversation_id,
      claim: claim.claim,
      kind: claim.kind,
      holder: claim.holder,
      audience_scope: claim.audience_scope
    }

    case find_dedup_action(Repo, attrs, {embedding, signature}) do
      :insert ->
        put_embedding(claim, embedding, signature, now, :embedded)

      {:duplicate, existing} ->
        with {:ok, _claim} <-
               mark_superseded(claim, existing.id, :deduplicate) do
          {:ok, :deduplicated}
        end

      {:supersede, existing} ->
        if later_than?(claim, existing) do
          with {:ok, _claim} <- put_embedding(claim, embedding, signature, now),
               {:ok, _existing} <- mark_superseded(existing, claim.id) do
            {:ok, :superseded}
          end
        else
          with {:ok, _claim} <-
                 mark_superseded(claim, existing.id, :deduplicate) do
            {:ok, :deduplicated}
          end
        end
    end
  end

  defp attach_current_embedding(
         %Claim{claim_type: :take, active: true} = claim,
         embedding,
         signature,
         now
       ),
       do: put_embedding(claim, embedding, signature, now, :embedded)

  defp attach_current_embedding(_claim, _embedding, _signature, _now),
    do: {:ok, :stale}

  defp put_embedding(claim, embedding, signature, now, status \\ nil) do
    result =
      Ankole.Ash.update(claim, :record_embedding, %{
        embedding: embedding,
        embedding_signature: signature,
        embedding_error: nil,
        embedded_at: now,
        input_embedded_at: claim.embedded_at,
        input_signature: claim.embedding_signature
      })

    case {result, status} do
      {{:ok, updated}, nil} -> {:ok, updated}
      {{:ok, _updated}, status} -> {:ok, status}
      {{:error, _changeset} = error, _status} -> error
    end
  end

  defp later_than?(left, right) do
    case DateTime.compare(left.created_at, right.created_at) do
      :gt -> true
      :lt -> false
      :eq -> left.id > right.id
    end
  end

  defp parent_filter(query, %{object_slug: slug}) when is_binary(slug),
    do: where(query, [claim], claim.object_slug == ^slug)

  defp parent_filter(query, %{conversation_id: channel_id})
       when is_binary(channel_id),
       do: where(query, [claim], claim.conversation_id == ^channel_id)

  defp maybe_console_object(query, slug) when is_binary(slug) and slug != "",
    do: Ash.Query.filter(query, object_slug == ^slug)

  defp maybe_console_object(query, _slug), do: query

  defp maybe_console_type(query, "fact"), do: Ash.Query.filter(query, claim_type == :fact)
  defp maybe_console_type(query, "take"), do: Ash.Query.filter(query, claim_type == :take)
  defp maybe_console_type(query, _type), do: query

  defp maybe_console_status(query, "current"), do: Ash.Query.filter(query, current? == true)
  defp maybe_console_status(query, _status), do: query

  defp maybe_console_search(query, term) when is_binary(term) do
    case String.trim(term) do
      "" ->
        query

      term ->
        pattern = "%" <> Repo.escape_like(term) <> "%"

        Ash.Query.filter(
          query,
          fragment("? ILIKE ?", claim, ^pattern) or fragment("? ILIKE ?", kind, ^pattern) or
            fragment("? ILIKE ?", holder, ^pattern) or
            fragment("? ILIKE ?", object_slug, ^pattern) or
            fragment("?::text ILIKE ?", author, ^pattern)
        )
    end
  end

  defp maybe_console_search(query, _term), do: query

  defp normalized_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp insert_fact(attrs, embedding, signature, writer, opts) do
    now = DateTime.utc_now(:microsecond)

    attrs = %{
      author: Ankole.ActorRef.from_writer(writer, Repo.tenant_id!(), opts),
      object_slug: attrs[:object_slug],
      conversation_id: attrs[:conversation_id],
      claim: attrs[:claim],
      kind: attrs[:kind],
      holder: attrs[:holder],
      audience_scope: attrs[:audience_scope],
      notability: attrs[:notability],
      context: attrs[:context],
      valid_from: attrs[:valid_from],
      valid_until: attrs[:valid_until],
      confidence: attrs[:confidence] * 1.0,
      provenance_session: attrs[:provenance_session],
      provenance: attrs[:provenance],
      embedding: embedding,
      embedding_signature: signature,
      embedded_at: if(embedding, do: now)
    }

    Ankole.Ash.create(Claim, :record_fact, attrs)
  end

  defp mark_superseded(%Claim{} = old, new_claim_id, action \\ :supersede) do
    Ankole.Ash.update(old, action, %{superseded_by: new_claim_id})
  end

  defp validate_parent(attrs) do
    object_slug = attrs[:object_slug]
    channel_id = attrs[:conversation_id]

    cond do
      is_binary(object_slug) and is_nil(channel_id) ->
        case Objects.get_by_slug(object_slug) do
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

  defp validate_holder(holder) when is_binary(holder) and holder != "" do
    if Objects.valid_holder?(holder),
      do: :ok,
      else: {:error, {:unresolvable_holder, holder}}
  end

  defp validate_holder(_holder), do: {:error, :missing_holder}

  defp validate_scope(scope, :system), do: Scope.validate(scope)

  defp validate_scope(scope, writer_uid) when is_binary(writer_uid),
    do: Scope.validate_writable(scope, writer_uid)

  defp validate_required_provenance(provenance)
       when is_binary(provenance) and provenance != "" do
    :ok
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
             claim.author == Ankole.ActorRef.from_writer(writer_uid, Repo.tenant_id!(), []),
           do: :ok,
           else: {:error, :writer_not_in_claim_scope}
    end
  end

  defp ensure_not_superseded(%Claim{superseded_by: nil}), do: :ok
  defp ensure_not_superseded(%Claim{}), do: {:error, :already_superseded}

  defp ensure_claim_type(%Claim{claim_type: type}, type), do: :ok

  defp ensure_claim_type(%Claim{claim_type: actual}, expected),
    do: {:error, {:wrong_claim_type, Atom.to_string(actual), Atom.to_string(expected)}}

  defp ensure_unresolved(%Claim{resolved_at: nil}), do: :ok
  defp ensure_unresolved(%Claim{}), do: {:error, :already_resolved}

  defp lock_claim(claim_id) do
    Claim
    |> Ash.Query.filter(id == ^claim_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
    |> case do
      %Claim{} = claim -> {:ok, claim}
      nil -> {:error, :not_found}
    end
  end
end
