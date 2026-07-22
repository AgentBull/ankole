defmodule Ankole.Brain.Citations do
  @moduledoc """
  Parses strict `src:` markers and maintains their rebuildable block index.

  The block body remains canonical. The index exists so source impact, Console
  navigation, linting, and withdrawal do not each invent a different parser.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Scope
  alias Ankole.Brain.Knowledge.WriteAuthority
  alias Ankole.Brain.Schemas.BlockCitation
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Sources

  @citation ~r/(?<![A-Za-z0-9_-])src:((?:signal-gateway-entry|brain-source):[A-Za-z0-9_-]+)(?![A-Za-z0-9_:-])/
  @empty_parentheses ~r/\(\s*\)/u
  @repeated_horizontal_space ~r/[ \t]{2,}/u
  @space_before_punctuation ~r/[ \t]+([,.;:!?])/u
  @source_marker ~r/(?<![A-Za-z0-9_-])src:\S*/u

  @doc "Returns unique source document ids in first-appearance order."
  @spec document_ids(String.t()) :: [String.t()]
  def document_ids(body) when is_binary(body) do
    @citation
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  def document_ids(_body), do: []

  @doc "Removes canonical source markers from a model-facing text projection."
  @spec remove_markers(String.t()) :: String.t()
  def remove_markers(body) when is_binary(body) do
    body
    |> then(&Regex.replace(@citation, &1, ""))
    |> then(&Regex.replace(@empty_parentheses, &1, ""))
    |> then(&Regex.replace(@space_before_punctuation, &1, "\\1"))
    |> then(&Regex.replace(@repeated_horizontal_space, &1, " "))
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  @doc "Validates newly added refs and replaces one block's derived index."
  @spec sync(module(), Scope.t(), WriteAuthority.t(), EntryBlock.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def sync(
        repo,
        %Scope{} = scope,
        %WriteAuthority{} = authority,
        %EntryBlock{} = block,
        previous_body \\ nil
      ) do
    document_ids = document_ids(block.body)
    previous_ids = MapSet.new(document_ids(previous_body || ""))

    with :ok <- validate_syntax(block.body),
         :ok <- validate_new_refs(repo, scope, authority, document_ids, previous_ids) do
      replace(repo, block.id, document_ids)
    end
  end

  @doc "Rebuilds the index from already-authorized historical content during restore."
  @spec reindex(module(), EntryBlock.t()) :: :ok | {:error, term()}
  def reindex(repo, %EntryBlock{} = block), do: replace(repo, block.id, document_ids(block.body))

  @doc "Returns structured citations for one entry projection."
  @spec for_entry(module(), Ecto.UUID.t()) :: [map()]
  def for_entry(repo, entry_id) do
    BlockCitation
    |> join(:inner, [citation], block in EntryBlock, on: block.id == citation.block_id)
    |> where([_citation, block], block.entry_id == ^entry_id)
    |> order_by([citation, block], asc: block.position, asc: citation.document_id)
    |> select([citation, block], %{
      block_id: block.id,
      document_id: citation.document_id
    })
    |> repo.all()
    |> Enum.map(&Map.put(&1, :source_kind, source_kind(&1.document_id)))
  end

  @doc "Returns blocks currently claiming one source."
  @spec blocks_for_source(module(), String.t(), keyword()) :: [EntryBlock.t()]
  def blocks_for_source(repo, document_id, opts \\ []) do
    query =
      BlockCitation
      |> join(:inner, [citation], block in EntryBlock, on: block.id == citation.block_id)
      |> where([citation], citation.document_id == ^document_id)
      |> order_by([_citation, block], asc: block.entry_id, asc: block.position, asc: block.id)
      |> select([_citation, block], block)

    query = if Keyword.get(opts, :lock), do: lock(query, "FOR UPDATE"), else: query
    repo.all(query)
  end

  defp validate_new_refs(repo, scope, authority, document_ids, previous_ids) do
    document_ids
    |> Enum.reject(&MapSet.member?(previous_ids, &1))
    |> Enum.reduce_while(:ok, fn document_id, :ok ->
      case Sources.resolve(repo, scope, document_id) do
        {:ok, source} ->
          case WriteAuthority.authorize_citation(authority, source) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_source_citation, document_id, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_source_citation, document_id, reason}}}
      end
    end)
  end

  defp validate_syntax(body) do
    body
    |> then(&Regex.replace(@citation, &1, ""))
    |> then(&Regex.run(@source_marker, &1))
    |> case do
      nil -> :ok
      [marker] -> {:error, {:invalid_source_citation, marker, :malformed_document_id}}
    end
  end

  defp replace(repo, block_id, document_ids) do
    repo.delete_all(from citation in BlockCitation, where: citation.block_id == ^block_id)
    now = DateTime.utc_now(:microsecond)

    rows =
      Enum.map(document_ids, fn document_id ->
        %{
          block_id: block_id,
          document_id: document_id,
          inserted_at: now
        }
      end)

    case rows do
      [] ->
        :ok

      rows ->
        {_count, _rows} = repo.insert_all(BlockCitation, rows)
        :ok
    end
  rescue
    error in Ecto.ConstraintError -> {:error, error}
  end

  defp source_kind("signal-gateway-entry:" <> _id), do: "signal_message"
  defp source_kind("brain-source:" <> _id), do: "retained_source"
end
