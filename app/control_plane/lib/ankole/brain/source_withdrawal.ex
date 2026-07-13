defmodule Ankole.Brain.SourceWithdrawal do
  @moduledoc """
  Best-effort removal of knowledge blocks that cite a withdrawn chat source.

  The provider mirror remains the source of truth. A removal fact enqueues this
  mechanical job in the same ingress transaction; the job deletes only blocks
  containing the exact opaque `src:<document_id>` marker and uses Knowledge's
  normal audited mutation path so an operator can restore a false positive.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(document_id) when is_binary(document_id) do
    %{"document_id" => document_id}
    |> Ankole.Brain.Jobs.WithdrawSource.new()
    |> Oban.insert()
  end

  @spec withdraw(String.t()) :: {:ok, map()} | {:error, term()}
  def withdraw(document_id) when is_binary(document_id) do
    source_ref = "src:#{document_id}"
    source_pattern = Regex.escape(source_ref) <> "([^A-Za-z0-9_-]|$)"

    Repo.transact(fn repo ->
      blocks =
        EntryBlock
        |> where([block], fragment("? ~ ?", block.body, ^source_pattern))
        |> order_by([block], asc: block.entry_id, asc: block.position, asc: block.id)
        |> lock("FOR UPDATE")
        |> repo.all()

      Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, deleted} ->
        with {:ok, scope} <- Scope.for_store(block.owner_uid, block.store_key),
             {:ok, result} <-
               Knowledge.apply_mechanical_operation(
                 scope,
                 %{
                   operation: "delete_block",
                   entry_id: block.entry_id,
                   block_id: block.id,
                   expected_block_lock_version: block.lock_version
                 },
                 %{
                   "surface" => "source_withdrawal",
                   "source_document_id" => document_id,
                   "source_ref" => source_ref
                 },
                 repo: repo
               ) do
          {:cont, {:ok, result.results ++ deleted}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, results} ->
          {:ok,
           %{
             status: :completed,
             document_id: document_id,
             deleted_block_count: length(results),
             results: Enum.reverse(results)
           }}

        {:error, _reason} = error ->
          error
      end
    end)
  end
end
