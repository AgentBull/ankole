defmodule Ankole.Brain.SourceWithdrawal do
  @moduledoc """
  Best-effort withdrawal of Brain knowledge caused by a removed chat source.

  The provider mirror remains the source of truth. A removal fact enqueues this
  mechanical job in the same ingress transaction. The job first reverses
  unchanged `memory_update` audits from ActorEvents whose only current input was
  the removed entry, then deletes blocks containing the exact opaque
  `src:<document_id>` marker. Both paths use Knowledge's audited recovery seam.
  """

  import Ecto.Query, only: [from: 2]

  alias Ankole.Brain.Citations
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Repo

  @spec enqueue(String.t(), [Ecto.UUID.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(document_id, actor_event_ids \\ [])

  def enqueue(document_id, actor_event_ids)
      when is_binary(document_id) and is_list(actor_event_ids) do
    with {:ok, actor_event_ids} <- normalize_actor_event_ids(actor_event_ids) do
      %{
        "document_id" => document_id,
        "actor_event_ids" => actor_event_ids
      }
      |> Ankole.Brain.Jobs.WithdrawSource.new()
      |> Oban.insert()
    end
  end

  @spec withdraw(String.t(), [Ecto.UUID.t()]) :: {:ok, map()} | {:error, term()}
  def withdraw(document_id, actor_event_ids \\ [])

  def withdraw(document_id, actor_event_ids)
      when is_binary(document_id) and is_list(actor_event_ids) do
    source_ref = "src:#{document_id}"

    with {:ok, actor_event_ids} <- normalize_actor_event_ids(actor_event_ids) do
      Repo.transact(fn repo ->
        with {:ok, causal} <- withdraw_causal_updates(repo, actor_event_ids, document_id),
             {:ok, citation_results} <- withdraw_citations(repo, document_id, source_ref) do
          {:ok,
           %{
             status: :completed,
             document_id: document_id,
             restored_causal_update_count: length(causal.restored),
             skipped_causal_update_count: length(causal.skipped),
             deleted_block_count: length(citation_results),
             causal_restorations: causal.restored,
             skipped_causal_updates: causal.skipped,
             results: citation_results
           }}
        end
      end)
    end
  end

  defp withdraw_causal_updates(_repo, [], _document_id),
    do: {:ok, %{restored: [], skipped: []}}

  defp withdraw_causal_updates(repo, actor_event_ids, document_id) do
    actor_event_ids
    |> causal_audits(repo)
    |> Enum.reduce_while({:ok, %{restored: [], skipped: []}}, fn audit, {:ok, result} ->
      cond do
        audit_already_restored?(repo, audit) ->
          skipped = [%{audit_id: audit.id, reason: :already_restored} | result.skipped]
          {:cont, {:ok, %{result | skipped: skipped}}}

        true ->
          with {:ok, scope} <- Scope.for_store(audit.owner_uid, audit.store_key),
               {:ok, restoration} <-
                 Knowledge.restore_mechanical_audit(
                   scope,
                   audit.id,
                   %{
                     "surface" => "source_withdrawal",
                     "source_actor_event_id" => audit.metadata["actor_event_id"],
                     "source_document_id" => document_id
                   },
                   repo: repo
                 ) do
            {:cont, {:ok, %{result | restored: [restoration | result.restored]}}}
          else
            {:error, reason} ->
              if safe_restore_skip?(reason) do
                skipped = [%{audit_id: audit.id, reason: reason} | result.skipped]
                {:cont, {:ok, %{result | skipped: skipped}}}
              else
                {:halt, {:error, reason}}
              end
          end
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok,
         %{
           restored: Enum.reverse(result.restored),
           skipped: Enum.reverse(result.skipped)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp causal_audits(actor_event_ids, repo) do
    repo.all(
      from audit in AuditLog,
        where: fragment("?->>'surface' = 'memory_update'", audit.metadata),
        where: fragment("?->>'actor_event_id'", audit.metadata) in ^actor_event_ids,
        order_by: [desc: audit.inserted_at, desc: audit.id]
    )
  end

  defp audit_already_restored?(repo, audit) do
    repo.exists?(
      from inverse in AuditLog,
        where: inverse.owner_uid == ^audit.owner_uid,
        where: fragment("?->>'restored_audit_id' = ?", inverse.metadata, ^audit.id)
    )
  end

  defp safe_restore_skip?({:audit_restore_conflict, _details}), do: true
  defp safe_restore_skip?(:not_found), do: true
  defp safe_restore_skip?(_reason), do: false

  defp withdraw_citations(repo, document_id, source_ref) do
    repo
    |> Citations.blocks_for_source(document_id, lock: true)
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, deleted} ->
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
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_actor_event_ids(actor_event_ids) do
    Enum.reduce_while(actor_event_ids, {:ok, []}, fn actor_event_id, {:ok, ids} ->
      case Ecto.UUID.cast(actor_event_id) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, {:error, :invalid_source_actor_event_id}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end
end
