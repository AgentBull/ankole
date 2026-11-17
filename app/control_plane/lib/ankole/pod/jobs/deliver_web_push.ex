defmodule Ankole.Pod.Jobs.DeliverWebPush do
  @moduledoc "Pushes a room's newest notifiable message to the browsers of the Humans it notifies."

  use Ankole.Job,
    tenancy: :tenant,
    queue: :outbox,
    max_attempts: 3,
    # Messages that commit while a delivery waits join it instead of adding another.
    unique: [
      period: :infinity,
      keys: [:conversation_id],
      states: [:available, :scheduled]
    ]

  # A busy room waits for a quiet moment, but no longer than this after the first message.
  @max_wait_seconds 60

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"conversation_id" => id}, inserted_at: inserted_at}) do
    now = DateTime.utc_now()

    settled_before =
      if DateTime.diff(now, inserted_at) < @max_wait_seconds,
        do: DateTime.add(now, -Ankole.Pod.WebPush.delay_seconds())

    Ankole.Pod.WebPush.deliver(id, settled_before: settled_before)
  end
end
