defmodule Ankole.AutomationJobs.Queue do
  @moduledoc "Serial Run admission and event-driven slice handoff under the Job row lock."
  require Ash.Query
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.AutomationJobs.Jobs.ExecuteRun

  def enqueue_in_tx(job, event, opts) do
    key = Keyword.get(opts, :concurrency_key, "default")

    attrs = %{
      automation_job_id: job.id,
      event: event,
      concurrency_key: key,
      coalesce_key: if(job.concurrency_mode == :serial_coalesce, do: key),
      signal_id: Keyword.get(opts, :signal_id),
      binding_id: Keyword.get(opts, :binding_id),
      causation_id: Keyword.get(opts, :causation_id),
      correlation_id: Keyword.get(opts, :correlation_id)
    }

    case pending_tail(job, key) do
      nil ->
        with {:ok, run} <- Ankole.Ash.create(Run, :enqueue, attrs),
             :ok <- schedule_head(job, run, opts) do
          {:ok, %{status: :queued, automation_job_run: run, coalesced: false}}
        end

      run ->
        with {:ok, run} <-
               Ankole.Ash.update(
                 run,
                 :coalesce,
                 Map.take(attrs, [:event, :signal_id, :binding_id, :causation_id, :correlation_id])
               ) do
          {:ok, %{status: :queued, automation_job_run: run, coalesced: true}}
        end
    end
  end

  defp pending_tail(%{concurrency_mode: :serial_coalesce, id: id}, key) do
    Run
    |> Ash.Query.filter(
      automation_job_id == ^id and coalesce_key == ^key and
        status == :queued and attempts == 0 and slice_count == 0
    )
    |> Ankole.Ash.read_one!()
  end

  defp pending_tail(_, _), do: nil

  def startable?(job, run, expected_slice) do
    run.slice_count == expected_slice and head?(job, run)
  end

  defp head?(%{concurrency_mode: :parallel}, _run), do: true

  defp head?(job, run) do
    not (Run
         |> Ash.Query.filter(
           automation_job_id == ^job.id and concurrency_key == ^run.concurrency_key and
             id != ^run.id and (status == :running or (status == :queued and id < ^run.id))
         )
         |> Ankole.Ash.exists?())
  end

  def schedule_head(job, run, opts \\ []) do
    if head?(job, run), do: insert(run, opts), else: :ok
  end

  def insert(run, opts \\ []) do
    insert = Keyword.get(opts, :wake_insert, &Oban.insert/1)

    case ExecuteRun.new(
           %{"automation_job_run_id" => run.id, "expected_slice_count" => run.slice_count},
           schedule_in: Keyword.get(opts, :delay_seconds, 0)
         )
         |> insert.() do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def wake_next(%{concurrency_mode: :parallel}, _run), do: :ok

  def wake_next(job, run) do
    next =
      Run
      |> Ash.Query.filter(
        automation_job_id == ^job.id and concurrency_key == ^run.concurrency_key and
          status == :queued
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    if next, do: schedule_head(job, next), else: :ok
  end

  def policy_changed(%{concurrency_mode: previous}, %{concurrency_mode: :parallel} = job)
      when previous != :parallel do
    Run
    |> Ash.Query.filter(automation_job_id == ^job.id and status == :queued)
    |> Ash.Query.sort(id: :asc)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn run, :ok ->
      case insert(run) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def policy_changed(_previous, _current), do: :ok
end
