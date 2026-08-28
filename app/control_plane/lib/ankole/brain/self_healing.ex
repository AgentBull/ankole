defmodule Ankole.Brain.SelfHealing do
  @moduledoc """
  Mechanical, model-free maintenance of the Brain projections.

  One sweep rechunks objects whose chunking signature is stale, re-embeds
  chunks and claims whose embedding state is missing, failed, or built with
  another model signature, rebuilds the recoverable search indexes, and
  enqueues extraction for idle channels with pending slices.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Jobs.ProcessChannelSlice
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.SearchIndexes
  alias Ankole.Brain.SignalsLearning
  alias Ankole.Logging
  alias Ankole.Repo

  @embed_batch_limit 500
  @embed_call_size 64
  @rechunk_batch_limit 100

  @doc """
  Runs one full sweep and returns a report of the work done.
  """
  @spec sweep() :: {:ok, map()} | {:error, term()}
  def sweep do
    if Config.enabled?() do
      # Library knowledge first: pages it lands get their chunks and
      # embeddings in the same sweep instead of one cycle later.
      library_knowledge = sync_library_knowledge()
      rechunked = rechunk_stale_objects()
      embedded = embed_pending()
      indexes = ensure_indexes()
      slices = sweep_idle_channels()

      {:ok,
       %{
         library_knowledge: library_knowledge,
         rechunked: rechunked,
         embedded: embedded,
         indexes: indexes,
         slices: slices
       }}
    else
      {:ok, %{status: :brain_disabled}}
    end
  end

  @doc """
  Rechunks objects whose chunking signature differs from the current one.
  """
  @spec rechunk_stale_objects() :: non_neg_integer()
  def rechunk_stale_objects do
    chunking = Config.chunking()
    signature = Chunker.signature(chunking)

    Object
    |> where([object], is_nil(object.deleted_at))
    |> where(
      [object],
      is_nil(object.chunking_signature) or object.chunking_signature != ^signature
    )
    |> limit(@rechunk_batch_limit)
    |> Repo.all()
    |> Enum.count(fn object ->
      match?({:ok, _object}, Objects.reconcile_chunks(object, chunking: chunking))
    end)
  end

  @doc """
  Embeds pending, failed, or signature-stale chunks and claims, up to the
  per-sweep batch limit. Without a configured embedding model the sweep
  reports zero work.
  """
  @spec embed_pending() :: %{chunks: non_neg_integer(), claims: non_neg_integer()}
  def embed_pending do
    case Embeddings.signature() do
      {:ok, signature} ->
        %{
          chunks: embed_pending_chunks(signature),
          claims: embed_pending_claims(signature)
        }

      {:error, _reason} ->
        %{chunks: 0, claims: 0}
    end
  end

  defp embed_pending_chunks(signature) do
    Chunk
    |> where(
      [chunk],
      is_nil(chunk.embedded_at) or chunk.embedding_signature != ^signature
    )
    # Never-tried rows go first, so a set of permanently failing rows cannot
    # starve fresh content out of the per-sweep batch.
    |> order_by([chunk], asc: fragment("? IS NOT NULL", chunk.embedding_error))
    |> limit(@embed_batch_limit)
    |> Repo.all()
    |> Enum.chunk_every(@embed_call_size)
    |> Enum.reduce(0, fn batch, count ->
      count + embed_batch(batch, signature, & &1.chunk_text)
    end)
  end

  defp embed_pending_claims(signature) do
    internal_prefix = Claims.internal_provenance_prefix() <> "%"

    Claim
    |> Claims.filter_live_parents()
    |> where(
      [claim],
      is_nil(claim.embedded_at) or claim.embedding_signature != ^signature
    )
    |> where([claim], not like(claim.provenance, ^internal_prefix))
    |> where(
      [claim],
      (claim.claim_type == "fact" and is_nil(claim.expired_at)) or
        (claim.claim_type == "take" and claim.active == true)
    )
    |> order_by([claim], asc: fragment("? IS NOT NULL", claim.embedding_error))
    |> limit(@embed_batch_limit)
    |> Repo.all()
    |> Enum.chunk_every(@embed_call_size)
    |> Enum.reduce(0, fn batch, count ->
      count + embed_batch(batch, signature, & &1.claim)
    end)
  end

  defp embed_batch(rows, target_signature, text_fun) do
    texts = Enum.map(rows, text_fun)
    now = DateTime.utc_now(:microsecond)

    case Embeddings.embed_texts(texts) do
      {:ok, {vectors, signature}} ->
        rows
        |> Enum.zip(vectors)
        |> Enum.each(fn {row, vector} ->
          row
          |> Ecto.Changeset.change(
            embedding: vector,
            embedding_signature: signature,
            embedding_error: nil,
            embedded_at: now
          )
          |> Repo.update!()
        end)

        length(rows)

      {:error, reason} ->
        error = reason |> inspect() |> String.slice(0, 500)

        Enum.each(rows, fn row ->
          row
          |> Ecto.Changeset.change(
            embedding: nil,
            embedding_signature: target_signature,
            embedding_error: error,
            embedded_at: nil
          )
          |> Repo.update!()
        end)

        0
    end
  end

  defp ensure_indexes do
    case SearchIndexes.ensure_current() do
      {:ok, actions} -> actions
      {:error, reason} -> [%{error: inspect(reason)}]
    end
  end

  defp sync_library_knowledge do
    case LibraryKnowledge.sync() do
      {:ok, report} ->
        report

      {:error, reason} ->
        Logging.warning(
          "brain.self_healing.library_knowledge_failed",
          "library knowledge synchronization failed",
          %{reason: inspect(reason)}
        )

        %{status: :error, reason: inspect(reason)}
    end
  end

  defp sweep_idle_channels do
    channel_ids = SignalsLearning.idle_channels_with_pending_slices()

    Enum.each(channel_ids, &ProcessChannelSlice.enqueue/1)
    length(channel_ids)
  end
end
