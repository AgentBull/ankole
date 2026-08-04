defmodule Ankole.Brain do
  @moduledoc """
  PostgreSQL-backed Brain for one accountable principal.

  Structured knowledge is durable truth. Markdown projections, search results,
  Brain coordinates evidence, curation, current knowledge, and human review.
  SignalsGateway continues to own chat evidence; Brain owns retained source bytes,
  curated knowledge, dreaming state, and recovery records.
  """

  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.Embeddings
  alias Ankole.Brain.Dreaming.StageA
  alias Ankole.Brain.Dreaming.StageB
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Recall.Chat
  alias Ankole.Brain.Recall.Search
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Sources
  alias Ankole.Brain.SourceWithdrawal
  alias Ankole.Brain.Status
  alias Ankole.Brain.Supervision

  @spec ensure_registered() :: :ok | {:error, term()}
  defdelegate ensure_registered(), to: Config

  @spec search(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate search(scope, attrs), to: Search

  @spec browse(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def browse(%Scope{} = scope, attrs) when is_map(attrs) do
    case Map.get(attrs, "document_id") || Map.get(attrs, :document_id) do
      "brain-source:" <> _id = document_id -> Sources.open_model(scope, document_id)
      _chat_request -> Chat.browse(scope, attrs)
    end
  end

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

  @spec resolve_source(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_source(owner_uid, document_id), to: Supervision

  @spec list_sources(String.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_sources(owner_uid), to: Supervision

  @spec capture_source(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate capture_source(owner_uid, store_key, attrs, creator_uid, opts \\ []),
    to: Supervision

  @spec learn_source(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate learn_source(owner_uid, document_id, opts \\ []), to: Supervision

  @spec source_raw(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate source_raw(owner_uid, document_id), to: Supervision

  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate status(owner_uid), to: Status, as: :run

  @spec dreaming_fitness(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate dreaming_fitness(owner_uid, opts \\ []), to: Supervision

  @spec health_check(Scope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate health_check(scope), to: Status, as: :run

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
