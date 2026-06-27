defmodule Ankole.ActorRuntime.Jobs.FireScheduledEvent do
  @moduledoc """
  Oban wake edge for one scheduled actor event.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [
      fields: [:worker, :args],
      keys: [:scheduled_event_id],
      states: :incomplete
    ]

  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.Schedule

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scheduled_event_id" => scheduled_event_id}})
      when is_binary(scheduled_event_id) do
    case Schedule.fire_due_event(scheduled_event_id) do
      {:ok, %{status: :fired}} ->
        ActivationManager.wake()
        :ok

      {:ok, %{status: :noop}} ->
        :ok

      {:ok, %{status: :cancelled}} ->
        :ok

      {:error, {:permanent, reason}} ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :missing_scheduled_event_id}
end
