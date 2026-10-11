defmodule Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent do
  @moduledoc """
  Oban wake edge for one scheduled actor event.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 10,
    unique: [
      fields: [:worker, :args],
      keys: [:scheduled_event_id],
      states: [:available, :scheduled, :retryable]
    ]

  alias Ankole.Schedule

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def run(%Oban.Job{
        args: %{"scheduled_event_id" => scheduled_event_id},
        attempt: attempt,
        max_attempts: max_attempts
      })
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    case Schedule.fire_due_event(scheduled_event_id,
           attempt: attempt,
           max_attempts: max_attempts
         ) do
      {:ok, %{status: :fired}} ->
        :ok

      {:ok, %{status: :noop}} ->
        :ok

      {:ok, %{status: :cancelled}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(%Oban.Job{}), do: {:cancel, :missing_scheduled_event_id}
end
