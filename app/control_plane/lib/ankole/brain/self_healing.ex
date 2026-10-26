defmodule Ankole.Brain.SelfHealing do
  @moduledoc """
  Mechanical, model-free maintenance of the Brain projections.

  One sweep rechunks objects whose chunking signature is stale, re-embeds
  chunks and claims whose embedding state is missing, failed, or built with
  another model signature, and
  enqueues extraction for idle channels and stored OIDC Client conversations.
  """

  require Ash.Query

  alias Ankole.Brain.Chunks
  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Jobs.ProcessConversationSlice
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Links
  alias Ankole.Brain.OIDCClientLearning
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.ConversationsLearning
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
      linked = reconcile_body_links()
      embedded = embed_pending()
      slices = sweep_idle_channels()
      oidc_sources = OIDCClientLearning.sweep()

      {:ok,
       %{
         library_knowledge: library_knowledge,
         rechunked: rechunked,
         linked: linked,
         embedded: embedded,
         slices: slices,
         oidc_sources: oidc_sources
       }}
    else
      {:ok, %{status: :brain_disabled}}
    end
  end

  @doc "Reconciles stale body links independently of model configuration."
  def reconcile_body_links do
    Object
    |> Ash.Query.filter(
      is_nil(deleted_at) and (is_nil(links_extracted_at) or links_extracted_at < updated_at)
    )
    |> Ash.Query.limit(@rechunk_batch_limit)
    |> Ankole.Ash.read!()
    |> Enum.count(fn object ->
      match?(
        {:ok, _},
        Repo.transact_top_level(fn -> Links.reconcile_object_links_in_tx(object.slug) end)
      )
    end)
  end

  # Rechunks objects whose chunking signature differs from the current one.
  #
  @spec rechunk_stale_objects() :: non_neg_integer()
  defp rechunk_stale_objects do
    chunking = Config.chunking()
    signature = Chunker.signature(chunking)

    Object
    |> Ash.Query.filter(
      is_nil(deleted_at) and (is_nil(chunking_signature) or chunking_signature != ^signature)
    )
    |> Ash.Query.limit(@rechunk_batch_limit)
    |> Ankole.Ash.read!()
    |> Enum.count(fn object ->
      match?(
        {:ok, _object},
        Repo.transact_top_level(fn -> Chunks.reconcile_in_tx(object, chunking: chunking) end)
      )
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
    |> Ash.Query.filter(is_nil(embedded_at) or embedding_signature != ^signature)
    # Never-tried rows go first, so a set of permanently failing rows cannot
    # starve fresh content out of the per-sweep batch.
    |> Ash.Query.sort(embedding_failed?: :asc)
    |> Ash.Query.limit(@embed_batch_limit)
    |> Ankole.Ash.read!()
    |> Enum.chunk_every(@embed_call_size)
    |> Enum.reduce(0, fn batch, count ->
      count + embed_batch(batch, signature, & &1.chunk_text)
    end)
  end

  defp embed_pending_claims(signature) do
    Claim
    |> Ash.Query.filter(
      live_parent? and current? and
        (is_nil(embedded_at) or embedding_signature != ^signature)
    )
    |> Ash.Query.sort(embedding_failed?: :asc)
    |> Ash.Query.limit(@embed_batch_limit)
    |> Ankole.Ash.read!()
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
        |> Enum.count(fn
          {%Claim{} = claim, vector} ->
            {:ok, status} =
              Repo.transact_top_level(fn ->
                Claims.attach_embedding_in_tx(claim, vector, signature, now)
              end)

            status != :stale

          {%Chunk{} = chunk, vector} ->
            Chunks.record_embedding(chunk, {:ok, vector, signature}, now: now) ==
              {:ok, :updated}
        end)

      {:error, reason} ->
        error = reason |> inspect() |> String.slice(0, 500)

        Enum.each(rows, fn
          %Chunk{} = chunk ->
            Chunks.record_embedding(chunk, {:error, error, target_signature}, now: now)

          %Claim{} = row ->
            {:ok, _status} = Claims.record_embedding_error(row, error, target_signature)
        end)

        0
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
    slices = ConversationsLearning.idle_pending_slices()
    Enum.each(slices, &ProcessConversationSlice.enqueue(&1.conversation_id))
    length(slices)
  end
end
