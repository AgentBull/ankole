defmodule Ankole.Pod.Jobs.ReconcileSearchIndex do
  @moduledoc """
  Periodic self-healing job that backfills missing Pod page search projections
  and advances bounded file-extraction reconciliation across active tenants.

  Shared BM25/HNSW retrieval index DDL is owned and scheduled solely by
  `Ankole.Brain.Jobs.Tick` through `Ankole.SearchIndexes.ensure_current/0`.
  """

  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  @impl Ankole.Job
  def run(%Oban.Job{}) do
    Ankole.Tenants.map_active(&Ankole.Pod.FileExtraction.reconcile_tenant_batch/0)
    |> Ankole.Tenants.fanout_result()
  end
end
