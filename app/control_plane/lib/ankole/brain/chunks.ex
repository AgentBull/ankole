defmodule Ankole.Brain.Chunks do
  @moduledoc """
  Maintains current retrieval positions and records fenced embedding results.

  Body chunks precede timeline chunks. An unchanged position retains its row
  and vector; a changed position invalidates vector state. Embeddings do not
  move between positions. The `:reconcile_chunks` action of
  `Ankole.Brain.Schemas.Object` owns the transaction of a reconcile.
  """
  require Ash.Query

  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Config
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Repo

  @doc """
  Reconciles an object's positions in the caller's transaction, under the
  current persisted row lock. `chunking:` overrides the configured chunking.
  """
  @spec reconcile_in_tx(Object.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def reconcile_in_tx(%Object{} = object, opts \\ []) do
    chunking = Keyword.get(opts, :chunking) || Config.chunking()

    with :ok <- Repo.require_transaction() do
      Object
      |> Ash.Query.filter(id == ^object.id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!()
      |> case do
        %Object{} = current -> reconcile_current(current, chunking)
        nil -> {:error, :not_found}
      end
    end
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

  defp reconcile_current(object, chunking) do
    with {:ok, desired} <- desired_chunks(object, chunking),
         existing <- existing_positions(object.id),
         :ok <- remove_old_positions(object.id, existing, desired),
         :ok <- project_positions(object.id, existing, desired) do
      Ankole.Ash.update(object, :stamp_chunking, %{
        chunking_signature: Chunker.signature(chunking)
      })
    end
  end

  defp existing_positions(object_id) do
    Chunk
    |> Ash.Query.filter(object_id == ^object_id)
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.chunk_index, &1})
  end

  defp remove_old_positions(object_id, existing, desired) do
    desired_indexes = MapSet.new(desired, & &1.chunk_index)
    stale_indexes = Enum.reject(Map.keys(existing), &MapSet.member?(desired_indexes, &1))

    if stale_indexes == [] do
      :ok
    else
      Chunk
      |> Ash.Query.filter(object_id == ^object_id and chunk_index in ^stale_indexes)
      |> Ankole.Ash.destroy_where(:remove_projection)
      |> written()
    end
  end

  defp project_positions(object_id, existing, desired) do
    Enum.reduce_while(desired, :ok, fn spec, :ok ->
      case project_position(object_id, Map.get(existing, spec.chunk_index), spec) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp project_position(object_id, nil, spec) do
    case Ankole.Ash.create(
           Chunk,
           :project,
           Map.merge(position_attrs(spec), %{
             object_id: object_id,
             chunk_index: spec.chunk_index
           })
         ) do
      {:ok, _chunk} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp project_position(_object_id, chunk, spec) do
    if chunk.chunk_text == spec.text and chunk.content_kind == spec.content_kind and
         chunk.audience_scope == spec.audience_scope do
      :ok
    else
      Chunk
      |> Ash.Query.filter(id == ^chunk.id)
      |> Ankole.Ash.update_where(:replace_projection, position_attrs(spec))
      |> written()
    end
  end

  defp position_attrs(spec) do
    %{
      content_kind: spec.content_kind,
      audience_scope: spec.audience_scope,
      chunk_text: spec.text,
      token_count: spec.token_count
    }
  end

  defp written({:ok, _records}), do: :ok
  defp written({:error, _error} = error), do: error

  defp desired_chunks(object, chunking) do
    with {:ok, segments} <- Markdoc.segments(object.body) do
      body_specs =
        Enum.flat_map(segments, fn segment ->
          segment.text
          |> Chunker.chunk_text(chunking)
          |> Enum.map(&%{content_kind: :body, audience_scope: segment.scope, text: &1.text})
        end)

      timeline_specs =
        Timeline
        |> Ash.Query.filter(object_slug == ^object.slug)
        |> Ash.Query.sort(date: :asc, id: :asc)
        |> Ankole.Ash.read!()
        |> Enum.flat_map(fn timeline ->
          timeline
          |> timeline_text()
          |> Chunker.chunk_text(chunking)
          |> Enum.map(
            &%{content_kind: :timeline, audience_scope: timeline.audience_scope, text: &1.text}
          )
        end)

      specs =
        (body_specs ++ timeline_specs)
        |> Enum.with_index()
        |> Enum.map(fn {spec, index} ->
          spec
          |> Map.put(:chunk_index, index)
          |> Map.put(:token_count, Chunker.estimate_tokens(spec.text))
        end)

      {:ok, specs}
    end
  end

  defp timeline_text(%Timeline{} = timeline) do
    date = Date.to_iso8601(timeline.date)

    case String.trim(timeline.detail || "") do
      "" -> "[#{date}] #{timeline.summary}"
      detail -> "[#{date}] #{timeline.summary} — #{detail}"
    end
  end
end
