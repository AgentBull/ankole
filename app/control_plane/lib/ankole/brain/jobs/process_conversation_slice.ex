defmodule Ankole.Brain.Jobs.ProcessConversationSlice do
  @moduledoc """
  Instance-level extraction task for one conversation slice.

  Uniqueness keeps one task per conversation across every non-terminal state with
  no look-back window, so a slice that runs longer than a minute cannot gain
  a concurrent twin. A watermark comparison under the Source row lock is
  the database fence. A slice invalidated by an in-slice edit snoozes and
  reruns, and a completed slice with more pending entries snoozes into the
  next slice, so a busy conversation drains without waiting for the next idle
  sweep.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:tenant_id, :conversation_id],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  alias Ankole.Brain.ConversationsLearning

  @slice_changed_snooze_seconds 10
  @drain_snooze_seconds 1

  @impl Ankole.Job
  def run(job) do
    if Ankole.Tenants.accepting_work?(Ankole.Repo.tenant_id!()), do: run_active(job), else: :ok
  end

  defp run_active(%Oban.Job{args: %{"conversation_id" => conversation_id}}) do
    case ConversationsLearning.process_conversation(conversation_id) do
      {:ok, %{status: :slice_changed}} ->
        {:snooze, @slice_changed_snooze_seconds}

      {:ok, %{pending_remaining: true}} ->
        {:snooze, @drain_snooze_seconds}

      {:ok, _status} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enqueues slice processing for one conversation.
  """
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(conversation_id) when is_binary(conversation_id) do
    %{"conversation_id" => conversation_id}
    |> new()
    |> Oban.insert()
  end
end
