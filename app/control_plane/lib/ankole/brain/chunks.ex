defmodule Ankole.Brain.Chunks do
  @moduledoc """
  Maintains current retrieval positions and records fenced embedding results.

  An unchanged position retains its row and vector while its page revision
  advances. Changed embedding inputs invalidate vector state. Embeddings never
  move between positions. Callers reconcile inside the Pod write transaction.
  """
  require Ash.Query

  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Config
  alias Ankole.Brain.Schemas.{Chunk, Timeline}
  alias Ankole.Brain.Schemas.Page, as: Object
  alias Ankole.Repo

  @doc """
  Reconciles an object's positions in the caller's transaction, under the
  current persisted row lock. `chunking:` overrides the configured chunking.
  """
  @spec reconcile_in_tx(Object.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def reconcile_in_tx(%Object{} = object, opts \\ []) do
    with :ok <- Repo.require_transaction(),
         {:ok, _} <- Ankole.Files.Nodes.lock(object.id),
         {:ok, current} <- Ankole.Brain.Objects.get_by_slug(object.id),
         do: reconcile_current(current, opts)
  end

  @doc "Reconciles content whose Pod writer already owns the row or inserted it in this transaction."
  def reconcile_locked_in_tx(%Object{} = object, opts \\ []) do
    with :ok <- Repo.require_transaction(), do: reconcile_current(object, opts)
  end

  @doc "Records a vector result only while the text and prior embedding state still match."
  @spec record_embedding(
          Chunk.t(),
          {:ok, Ash.Vector.t(), String.t()} | {:error, String.t(), String.t()},
          keyword()
        ) :: {:ok, :updated | :stale} | {:error, term()}
  def record_embedding(%Chunk{} = chunk, result, opts \\ []) do
    attrs =
      case result do
        {:ok, vector, signature} ->
          %{
            embedding: vector,
            embedding_signature: signature,
            embedding_error: nil,
            embedded_at: Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
          }

        {:error, error, signature} ->
          %{
            embedding: nil,
            embedding_signature: signature,
            embedding_error: error,
            embedded_at: nil
          }
      end

    input =
      Map.merge(attrs, %{
        input_text: chunk.chunk_text,
        input_page_revision: chunk.page_revision,
        input_chunking_signature: chunk.chunking_signature,
        input_embedded_at: chunk.embedded_at,
        input_signature: chunk.embedding_signature
      })

    Chunk
    |> Ash.Query.filter(id == ^chunk.id)
    |> Ankole.Ash.update_where(:record_embedding, input)
    |> case do
      {:ok, []} -> {:ok, :stale}
      {:ok, [_chunk]} -> {:ok, :updated}
      {:error, _error} = error -> error
    end
  end

  defp reconcile_current(object, opts) do
    with {:ok, desired} <- desired_chunks(object, opts),
         existing <- existing_positions(object.id),
         :ok <- remove_old_positions(object.id, existing, desired),
         :ok <- project_positions(object.id, existing, desired) do
      {:ok, object}
    end
  end

  defp existing_positions(page_id) do
    Chunk
    |> Ash.Query.filter(page_id == ^page_id)
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.chunk_index, &1})
  end

  defp remove_old_positions(page_id, existing, desired) do
    desired_indexes = MapSet.new(desired, & &1.chunk_index)
    stale_indexes = Enum.reject(Map.keys(existing), &MapSet.member?(desired_indexes, &1))

    if stale_indexes == [] do
      :ok
    else
      Chunk
      |> Ash.Query.filter(page_id == ^page_id and chunk_index in ^stale_indexes)
      |> Ankole.Ash.destroy_where(:remove_projection)
      |> written()
    end
  end

  defp project_positions(page_id, existing, desired) do
    Enum.reduce_while(desired, :ok, fn spec, :ok ->
      case project_position(page_id, Map.get(existing, spec.chunk_index), spec) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp project_position(page_id, nil, spec) do
    case Ankole.Ash.create(
           Chunk,
           :project,
           Map.merge(position_attrs(spec), %{
             page_id: page_id,
             chunk_index: spec.chunk_index
           })
         ) do
      {:ok, _chunk} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp project_position(_page_id, chunk, spec) do
    if chunk.chunk_text == spec.text and chunk.content_kind == spec.content_kind and
         chunk.source_node_id == spec.source_node_id and
         chunk.chunking_signature == spec.chunking_signature do
      advance_revision(chunk, spec)
    else
      Chunk
      |> Ash.Query.filter(id == ^chunk.id)
      |> Ankole.Ash.update_where(:replace_projection, position_attrs(spec))
      |> written()
    end
  end

  defp advance_revision(%{page_revision: revision}, %{page_revision: revision}), do: :ok

  defp advance_revision(chunk, spec) do
    Chunk
    |> Ash.Query.filter(id == ^chunk.id)
    |> Ankole.Ash.update_where(:advance_revision, %{page_revision: spec.page_revision})
    |> written()
  end

  defp position_attrs(spec) do
    %{
      content_kind: spec.content_kind,
      source_node_id: spec.source_node_id,
      chunk_text: spec.text,
      token_count: spec.token_count,
      page_revision: spec.page_revision,
      chunking_signature: spec.chunking_signature
    }
  end

  defp written({:ok, _records}), do: :ok
  defp written({:error, _error} = error), do: error

  def reconcile_node_in_tx(id, opts \\ []) do
    case Ankole.Brain.Objects.get_by_slug(id) do
      {:ok, page} ->
        reconcile_in_tx(page, opts)

      {:error, :not_found} ->
        with :ok <- Repo.require_transaction(),
             {:ok, node} <- Ankole.Files.Nodes.lock(id) do
          reconcile_current(
            %Object{id: id, kind: node.kind, body: "", revision: 0, deleted_at: node.deleted_at},
            opts
          )
        end
    end
  end

  defp desired_chunks(%{deleted_at: deleted}, _opts) when not is_nil(deleted), do: {:ok, []}

  defp desired_chunks(object, opts) do
    timelines =
      Timeline
      |> Ash.Query.filter(
        subject_page_id == ^object.id or
          (is_nil(subject_page_id) and source_node_id == ^object.id)
      )
      |> Ash.Query.sort(date: :asc, id: :asc)
      |> Ankole.Ash.read!()

    body = if Ankole.Brain.Knowledge.indexable?(object), do: String.trim(object.body), else: ""

    if body == "" and timelines == [] do
      {:ok, []}
    else
      chunking = Keyword.get(opts, :chunking) || Config.chunking()
      body_specs = specs(body, :body, object.id, chunking)

      timeline_specs =
        Enum.flat_map(timelines, fn timeline ->
          specs(timeline_text(timeline), :timeline, timeline.source_node_id, chunking)
        end)

      signature = Chunker.signature(chunking)

      {:ok,
       (body_specs ++ timeline_specs)
       |> Enum.with_index()
       |> Enum.map(fn {spec, index} ->
         Map.merge(spec, %{
           chunk_index: index,
           page_revision: object.revision,
           chunking_signature: signature
         })
       end)}
    end
  end

  defp specs("", _kind, _source, _chunking), do: []

  defp specs(text, kind, source, chunking) do
    text
    |> Chunker.chunk_text(chunking)
    |> Enum.map(fn chunk ->
      %{
        content_kind: kind,
        source_node_id: source,
        text: chunk.text,
        token_count: chunk.token_count
      }
    end)
  end

  defp timeline_text(timeline) do
    prefix = "[#{Date.to_iso8601(timeline.date)}] #{timeline.summary}"

    case String.trim(timeline.detail || "") do
      "" -> prefix
      detail -> prefix <> " — " <> detail
    end
  end
end
