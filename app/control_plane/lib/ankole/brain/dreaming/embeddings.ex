defmodule Ankole.Brain.Dreaming.Embeddings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Brain.Embedding
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Repo

  @spec embed_pending_blocks(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  def embed_pending_blocks(limit \\ 50) when is_integer(limit) and limit >= 0 do
    with {:ok, %{agent_uid: model_uid, dimensions: dimensions}} <- Embedding.resolve_model() do
      :ok = Embedding.prepare_space(model_uid, dimensions)

      blocks =
        EntryBlock
        |> join(:inner, [block], entry in Entry, on: entry.id == block.entry_id)
        |> where([block, _entry], block.embedding_state == :pending)
        |> order_by([block, _entry], asc: block.updated_at, asc: block.id)
        |> limit(^limit)
        |> select([block, entry], %{
          id: block.id,
          owner_uid: block.owner_uid,
          name: entry.name,
          type: entry.type,
          body: block.body,
          lock_version: block.lock_version
        })
        |> Repo.all()

      Enum.each(blocks, &embed_block(model_uid, &1))
      {:ok, length(blocks)}
    else
      {:error, reason} ->
        {:unavailable, "long-term memory embedding unavailable: #{inspect(reason)}"}
    end
  end

  defp embed_block(model_uid, block) do
    # Dates and attribution stay out of the vector text: they are useful
    # diagnostics but reduce semantic similarity quality.
    text = Enum.join([block.name, block.type, block.body], "\n")

    case Embedding.create(model_uid, text) do
      {:ok, vector, dimensions} ->
        Repo.query!(
          """
          UPDATE brain_entry_blocks
          SET embedding = $2,
              embedding_dimensions = $3,
              embedding_model_agent_uid = $4,
              embedding_state = 'synced',
              embedding_error = NULL
          WHERE id = $1::text::uuid
            AND body = $5
            AND lock_version = $6
            AND embedding_state = 'pending'
          """,
          [
            block.id,
            Embedding.storage_vector(vector),
            dimensions,
            model_uid,
            block.body,
            block.lock_version
          ]
        )

      {:error, reason} ->
        EntryBlock
        |> where(
          [stored],
          stored.id == ^block.id and stored.body == ^block.body and
            stored.lock_version == ^block.lock_version and stored.embedding_state == :pending
        )
        |> Repo.update_all(
          set: [
            embedding: nil,
            embedding_dimensions: nil,
            embedding_model_agent_uid: nil,
            embedding_state: :failed,
            embedding_error: inspect(reason)
          ]
        )
    end
  end
end
