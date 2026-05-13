defmodule BullX.Gateway.Mailbox do
  @moduledoc """
  Oban-backed durable mailbox for resolved Gateway `DeliveryIntent` values.

  The Mailbox owns persistence, retry, crash recovery, and per-delivery enqueue
  dedupe. It does not route Signals or choose consumers.
  """

  alias BullX.Gateway.{DeliveryIntent, SignalDeliveryWorker}
  alias BullX.Repo

  @type enqueue_status :: :enqueued | :duplicate
  @type enqueue_result :: {enqueue_status(), Oban.Job.t()}

  @spec enqueue(DeliveryIntent.t()) ::
          {:ok, enqueue_status(), Oban.Job.t()} | {:error, term()}
  def enqueue(%DeliveryIntent{} = intent) do
    with {:ok, intent} <- DeliveryIntent.validate(intent) do
      intent
      |> job_changeset()
      |> Oban.insert()
      |> normalize_insert_result()
    end
  end

  @spec enqueue_all([DeliveryIntent.t()]) :: {:ok, [enqueue_result()]} | {:error, term()}
  def enqueue_all([]), do: {:ok, []}

  def enqueue_all([_ | _] = intents) do
    with {:ok, intents} <- validate_intents(intents) do
      Ecto.Multi.new()
      |> to_multi(:mailbox, intents)
      |> Repo.transaction()
      |> case do
        {:ok, %{mailbox: results}} -> {:ok, results}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @spec to_multi(Ecto.Multi.t(), atom(), [DeliveryIntent.t()]) :: Ecto.Multi.t()
  def to_multi(%Ecto.Multi{} = multi, name, []) when is_atom(name) do
    Ecto.Multi.run(multi, name, fn _repo, _changes -> {:ok, []} end)
  end

  def to_multi(%Ecto.Multi{} = multi, name, intents) when is_atom(name) and is_list(intents) do
    intents
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {intent, index}, multi ->
      Oban.insert(multi, {:gateway_mailbox_job, name, index}, job_changeset(intent))
    end)
    |> Ecto.Multi.run(name, fn _repo, changes ->
      {:ok, collect_results(changes, name, length(intents))}
    end)
  end

  defp validate_intents(intents) do
    intents
    |> Enum.map(&DeliveryIntent.validate/1)
    |> case do
      results when is_list(results) ->
        case Enum.all?(results, &match?({:ok, _intent}, &1)) do
          true -> {:ok, Enum.map(results, fn {:ok, intent} -> intent end)}
          false -> Enum.find(results, &match?({:error, _reason}, &1))
        end
    end
  end

  @spec job_changeset(DeliveryIntent.t()) :: Ecto.Changeset.t()
  def job_changeset(%DeliveryIntent{} = intent) do
    SignalDeliveryWorker.new(DeliveryIntent.dump(intent),
      queue: intent.queue,
      priority: intent.priority,
      max_attempts: intent.max_attempts,
      meta: %{"delivery_key" => intent.delivery_key},
      unique: unique_opts()
    )
  end

  defp collect_results(changes, name, count) do
    for index <- 0..(count - 1)//1 do
      changes
      |> Map.fetch!({:gateway_mailbox_job, name, index})
      |> normalize_job()
    end
  end

  defp normalize_insert_result({:ok, %Oban.Job{} = job}) do
    {status, job} = normalize_job(job)
    {:ok, status, job}
  end

  defp normalize_insert_result({:error, reason}), do: {:error, reason}

  defp normalize_job(%Oban.Job{conflict?: true} = job), do: {:duplicate, job}
  defp normalize_job(%Oban.Job{} = job), do: {:enqueued, job}

  defp unique_opts do
    [
      fields: [:worker, :meta],
      states: :all,
      period: gateway_config(:mailbox_dedupe_window_seconds, 86_400)
    ]
  end

  defp gateway_config(key, default) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(key, default)
  end
end
