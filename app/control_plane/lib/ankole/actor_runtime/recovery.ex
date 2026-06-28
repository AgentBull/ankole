defmodule Ankole.ActorRuntime.Recovery do
  @moduledoc false

  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.Repo

  @doc """
  Fails started turns whose unlogged activation/delivery fence was lost.
  """
  @spec reconcile_projection_lost_started_turns(keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_projection_lost_started_turns(opts \\ []) do
    TurnLifecycle.reconcile_projection_lost_started_turns(opts)
  end

  @doc """
  Runs one actor-runtime watchdog pass.
  """
  @spec watchdog_once(keyword()) :: {:ok, map()} | {:error, term()}
  def watchdog_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 60)
    stale_worker_ttl_seconds = Keyword.get(opts, :stale_worker_ttl_seconds, 3_600)
    lease_grace_seconds = Keyword.get(opts, :lease_grace_seconds, 0)

    Repo.transact(fn repo ->
      with {:ok, stale_workers} <-
             WorkerAdmission.mark_stale_workers(repo, now, stale_after_seconds),
           {:ok, expired_activations} <-
             TurnLifecycle.fail_expired_activations(repo, now, lease_grace_seconds),
           {:ok, projection_lost_turns} <-
             TurnLifecycle.reconcile_projection_lost_started_turns_in_tx(repo, now),
           {deleted_stale_workers, _rows} <-
             WorkerAdmission.delete_expired_stale_workers(repo, now, stale_worker_ttl_seconds) do
        {:ok,
         %{
           stale_workers: stale_workers,
           expired_activations: expired_activations,
           projection_lost_turns: projection_lost_turns,
           deleted_stale_workers: deleted_stale_workers
         }}
      end
    end)
  end
end
