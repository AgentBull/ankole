defmodule BullX.AIAgent.AmbientBatchWorker do
  @moduledoc """
  Polls the ambient batch store and starts due batch processors.

  The worker owns only timing. Batch contents live in the batch store and the
  processor is safe to spawn independently, so restarting this GenServer should
  only delay ambient intervention, not lose committed IM facts.
  """

  use GenServer

  alias BullX.AIAgent.{AmbientBatch, AmbientBatchProcessor}

  @interval_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    process_due()
    schedule()
    {:noreply, state}
  end

  defp process_due do
    case AmbientBatch.due_batches() do
      {:ok, batch_keys} -> Enum.each(batch_keys, &AmbientBatchProcessor.start/1)
      {:error, _reason} -> :ok
    end
  end

  defp schedule, do: Process.send_after(self(), :poll, @interval_ms)
end
