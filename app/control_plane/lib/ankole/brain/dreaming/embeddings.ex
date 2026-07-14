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

    model_by_owner =
      blocks
      |> Enum.map(& &1.owner_uid)
      |> Enum.uniq()
      |> Map.new(&{&1, Embedding.resolve_model_agent_uid(&1)})

    {attempted_count, unavailable} =
      Enum.reduce(blocks, {0, []}, fn block, {count, unavailable} ->
        case Map.fetch!(model_by_owner, block.owner_uid) do
          {:ok, model_uid} ->
            embed_block(model_uid, block)
            {count + 1, unavailable}

          {:error, reason} ->
            {count, [{block.owner_uid, reason} | unavailable]}
        end
      end)

    case {attempted_count, unavailable} do
      {0, [{owner_uid, reason} | _rest]} ->
        {:unavailable, "brain embedding unavailable for #{owner_uid}: #{inspect(reason)}"}

      _result ->
        {:ok, attempted_count}
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
          SET embedding = $2::text::vector,
              embedding_dimensions = $3,
              embedding_state = 'synced',
              embedding_error = NULL
          WHERE id = $1::text::uuid
            AND body = $4
            AND lock_version = $5
            AND embedding_state = 'pending'
          """,
          [block.id, Embedding.to_pgvector(vector), dimensions, block.body, block.lock_version]
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
            embedding_state: :failed,
            embedding_error: inspect(reason)
          ]
        )
    end
  end
end
