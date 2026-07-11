defmodule Ankole.Memory do
  @moduledoc """
  Public context for curated notes and historical recall.

  This module is the stable seam used by actor runtime and memory RPC callers. The implementation is
  grouped under `Ankole.Memory` by responsibility so callers do not need to know whether an operation
  is backed by notes, episode projection, or historical retrieval.
  """

  alias Ankole.Memory.ChannelCursor
  alias Ankole.Memory.Config
  alias Ankole.Memory.EpisodePipeline
  alias Ankole.Memory.Note
  alias Ankole.Memory.Notes
  alias Ankole.Memory.Recall.Browse
  alias Ankole.Memory.Recall.Search
  alias Ankole.SignalsGateway.Entry

  @type note_result :: {:ok, Note.t()} | {:error, term()}

  @doc """
  Registers Memory's operator-managed configuration keys.

  Returns `:ok` when every definition is registered, or `{:error, reason}` when registration fails.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  defdelegate ensure_registered(), to: Config

  @doc """
  Lists curated notes visible to an agent in one signal channel.

  Agent UIDs are normalized to lowercase before querying. Notes are returned oldest first as
  boundary maps suitable for prompt and RPC payloads.
  """
  @spec list_notes(String.t(), String.t()) :: [map()]
  defdelegate list_notes(agent_uid, signal_channel_id), to: Notes

  @doc """
  Returns notes to inject into the current conversation context.

  A missing channel or disabled notes configuration produces an empty list rather than failing turn
  construction.
  """
  @spec notes_for_context(String.t(), String.t() | nil) :: [map()]
  defdelegate notes_for_context(agent_uid, signal_channel_id), to: Notes

  @doc """
  Saves a curated note within an agent-and-channel scope.

  Returns `{:ok, note}` on success. Disabled notes, invalid content, and per-channel quota failures
  are returned as `{:error, reason}`.
  """
  @spec save_note(String.t(), String.t(), String.t(), map()) :: note_result()
  defdelegate save_note(agent_uid, signal_channel_id, content, source \\ %{}), to: Notes

  @doc """
  Updates an agent-owned note without imposing a channel check.

  Prefer `update_note/4` at channel-boundary call sites such as RPC handling.
  """
  @spec update_note(String.t(), String.t(), String.t()) :: note_result()
  defdelegate update_note(agent_uid, note_id, content), to: Notes

  @doc """
  Updates a note only when it belongs to the supplied agent and channel.

  Cross-channel and missing notes intentionally share `:memory_note_not_found` so callers cannot use
  the operation to probe another channel's memory.
  """
  @spec update_note(String.t(), String.t() | nil, String.t(), String.t()) :: note_result()
  defdelegate update_note(agent_uid, signal_channel_id, note_id, content), to: Notes

  @doc """
  Deletes an agent-owned note without imposing a channel check.

  Prefer `forget_note/3` at channel-boundary call sites such as RPC handling.
  """
  @spec forget_note(String.t(), String.t()) :: {:ok, Note.t()} | {:error, term()}
  defdelegate forget_note(agent_uid, note_id), to: Notes

  @doc """
  Deletes a note only when it belongs to the supplied agent and channel.

  Returns `{:ok, note}` after deletion or `{:error, :memory_note_not_found}` when the scoped note is
  unavailable.
  """
  @spec forget_note(String.t(), String.t() | nil, String.t()) ::
          {:ok, Note.t()} | {:error, term()}
  defdelegate forget_note(agent_uid, signal_channel_id, note_id), to: Notes

  @doc """
  Searches permitted historical context using BM25 and, when available, episode embeddings.

  The response always describes degraded retrieval routes so the worker can distinguish a valid
  partial result from full hybrid recall.
  """
  @spec search(map()) :: {:ok, map()} | {:error, term()}
  defdelegate search(attrs), to: Search

  @doc """
  Browses one permitted historical channel in reverse chronological pages.

  Cursor values are opaque to callers and bind pagination to the entry's observed time plus source
  identifier.
  """
  @spec browse(map()) :: {:ok, map()} | {:error, term()}
  defdelegate browse(attrs), to: Browse

  @doc """
  Reports whether the configured light and embedding model profiles can run the recall pipeline.

  Returns `{:ok, status}` when both profiles resolve or `{:unavailable, reason}` otherwise.
  """
  @spec recall_pipeline_status() :: {:ok, map()} | {:unavailable, String.t()}
  defdelegate recall_pipeline_status(), to: EpisodePipeline

  @doc """
  Enqueues summary jobs for channels with eligible unprocessed history.

  Returns the number of jobs accepted by Oban, or `{:unavailable, reason}` when recall cannot run.
  """
  @spec enqueue_episode_summary_jobs(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  defdelegate enqueue_episode_summary_jobs(limit \\ 50), to: EpisodePipeline

  @doc """
  Summarizes the next eligible historical window for a channel.

  Model output is validated against the exact source window before episodes or cursor progress are
  committed. Returns `:ok` when processed or intentionally skipped, and `{:error, reason}` for a
  retryable failure.
  """
  @spec summarize_channel(String.t()) :: :ok | {:error, term()}
  defdelegate summarize_channel(signal_channel_id), to: EpisodePipeline

  @doc """
  Embeds pending memory episodes and records each episode's synced or failed state.

  Returns the number of attempted episodes, or `{:unavailable, reason}` when the model profiles cannot
  run.
  """
  @spec embed_pending_episodes(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  defdelegate embed_pending_episodes(limit \\ 20), to: EpisodePipeline

  @doc """
  Records why a channel's episode projection is currently unavailable.

  The cursor position is preserved; a later successful run may continue from the same durable point.
  """
  @spec mark_channel_unavailable(String.t(), String.t()) ::
          {:ok, ChannelCursor.t()} | {:error, term()}
  defdelegate mark_channel_unavailable(signal_channel_id, reason), to: EpisodePipeline

  @doc """
  Advances past a summary window after its final failed retry.

  The skipped span is emitted through telemetry because no episode is persisted for it. Returns `:ok`
  when no eligible window remains or the cursor was advanced.
  """
  @spec skip_failed_summary_window(String.t(), term()) :: :ok | {:error, term()}
  defdelegate skip_failed_summary_window(signal_channel_id, reason), to: EpisodePipeline

  @doc """
  Advances a channel cursor to a concrete signal entry.

  Ordering uses the entry's effective observed time and source identifier, matching subsequent window
  queries.
  """
  @spec advance_channel_cursor(String.t(), Entry.t()) ::
          {:ok, ChannelCursor.t()} | {:error, term()}
  defdelegate advance_channel_cursor(signal_channel_id, entry), to: EpisodePipeline

  @doc """
  Estimates text size with the same `o200k_base` tokenizer used by memory budgets.
  """
  @spec estimate_text_tokens(String.t()) :: non_neg_integer()
  def estimate_text_tokens(text) when is_binary(text) do
    Ankole.Kernel.estimate_o200k_base_tokens(text)
  end
end
