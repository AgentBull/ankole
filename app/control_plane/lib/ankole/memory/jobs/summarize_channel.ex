defmodule Ankole.Memory.Jobs.SummarizeChannel do
  @moduledoc """
  Summarizes one signal channel into Memory episodes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:signal_channel_id], period: 300]

  alias Ankole.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"signal_channel_id" => signal_channel_id}} = job)
      when is_binary(signal_channel_id) do
    case Memory.summarize_channel(signal_channel_id) do
      {:error, reason} = error ->
        if final_attempt?(job) do
          Memory.skip_failed_summary_window(signal_channel_id, reason)
        else
          error
        end

      result ->
        result
    end
  end

  def perform(%Oban.Job{}), do: {:error, :missing_signal_channel_id}

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts
end
