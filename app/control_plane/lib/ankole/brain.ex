defmodule Ankole.Brain do
  @moduledoc """
  PostgreSQL-backed Brain for one accountable principal.

  Structured knowledge is durable truth. Markdown projections, search results,
  frozen conversation snapshots, and dreaming output are read/write surfaces
  over that one relational model.
  """

  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.Embeddings
  alias Ankole.Brain.Dreaming.StageA
  alias Ankole.Brain.Dreaming.StageB
  alias Ankole.Brain.HealthCheck
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Recall.Chat
  alias Ankole.Brain.Recall.Search
  alias Ankole.Brain.Scope
  alias Ankole.Brain.SourceWithdrawal
  alias Ankole.Brain.Supervision

  @spec ensure_registered() :: :ok | {:error, term()}
  defdelegate ensure_registered(), to: Config

  @spec search(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate search(scope, attrs), to: Search

  @spec browse(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate browse(scope, attrs), to: Chat

  @spec open(Scope.t(), map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate open(scope, selector, opts \\ []), to: Knowledge

  @spec apply_operations(Scope.t(), map() | [map()], map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate apply_operations(scope, operations, actor, opts \\ []), to: Knowledge

  @spec list_entries(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate list_entries(owner_uid, opts \\ []), to: Supervision

  @spec open_entry(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate open_entry(owner_uid, selector), to: Supervision

  @spec apply_human_operations(String.t(), map() | [map()], String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate apply_human_operations(owner_uid, operations, actor_uid, opts \\ []),
    to: Supervision

  @spec list_audit(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate list_audit(owner_uid, opts \\ []), to: Supervision

  @spec restore_audit(String.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate restore_audit(owner_uid, audit_id, actor_uid), to: Supervision

  @spec restore_audits(String.t(), [Ecto.UUID.t()], String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate restore_audits(owner_uid, audit_ids, actor_uid), to: Supervision

  @spec resolve_source(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate resolve_source(document_id), to: Supervision

  @spec dreaming_fitness(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate dreaming_fitness(owner_uid, opts \\ []), to: Supervision

  @spec health_check(Scope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate health_check(scope), to: HealthCheck, as: :run

  @spec stage_a_status() :: {:ok, map()} | {:unavailable, String.t()}
  defdelegate stage_a_status(), to: StageA

  @spec enqueue_episode_summary_jobs(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  defdelegate enqueue_episode_summary_jobs(limit \\ 50), to: StageA

  @spec summarize_channel(String.t()) :: :ok | {:error, term()}
  defdelegate summarize_channel(signal_channel_id), to: StageA

  @spec embed_pending_episodes(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  defdelegate embed_pending_episodes(limit \\ 20), to: StageA

  @spec skip_failed_summary_window(String.t(), term()) :: :ok | {:error, term()}
  defdelegate skip_failed_summary_window(signal_channel_id, reason), to: StageA

  @spec embed_pending_blocks(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  defdelegate embed_pending_blocks(limit \\ 50), to: Embeddings

  @spec run_dreaming(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run_dreaming(principal_uid, opts \\ []), to: StageB, as: :run

  @spec withdraw_source(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate withdraw_source(document_id), to: SourceWithdrawal, as: :withdraw
end
