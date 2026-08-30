defmodule Ankole.Brain.Jobs.ProcessChannelSlice do
  @moduledoc """
  Instance-level extraction task for one Signal Channel slice.

  Uniqueness keeps one task per channel across every non-terminal state with
  no look-back window, so a slice that runs longer than a minute cannot gain
  a concurrent twin; the terminal claim's unique index is the database-level
  fence behind it. A slice invalidated by an in-slice edit snoozes and
  reruns, and a completed slice with more pending entries snoozes into the
  next slice, so a busy channel drains without waiting for the next idle
  sweep.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:channel_id],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  alias Ankole.Brain.SignalsLearning

  @slice_changed_snooze_seconds 10
  @drain_snooze_seconds 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id}}) do
    case SignalsLearning.process_channel(channel_id) do
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
  Enqueues slice processing for one channel.
  """
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(channel_id) when is_binary(channel_id) do
    %{"channel_id" => channel_id}
    |> new()
    |> Oban.insert()
  end
end
