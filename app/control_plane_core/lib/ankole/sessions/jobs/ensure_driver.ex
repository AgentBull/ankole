defmodule Ankole.Sessions.Jobs.EnsureDriver do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :conversations,
    max_attempts: 5,
    unique: [
      keys: [:agent_uid, :session_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ]

  # A later input cannot postpone an earlier committed wakeup.
  def enqueue(key, due_at \\ DateTime.utc_now(:microsecond)),
    do: Ankole.Job.schedule(__MODULE__, key, due_at || now(), only_earlier: true)

  def enqueue_in_tx(repo, key, due_at),
    do: Ankole.Job.schedule_in_tx(repo, __MODULE__, key, due_at || now(), only_earlier: true)

  defp now, do: DateTime.utc_now(:microsecond)

  @impl true
  def run(%Oban.Job{args: %{"agent_uid" => uid, "session_id" => session}}) do
    key = %{agent_uid: uid, session_id: session}

    case Ankole.Sessions.ensure_driver(key) do
      {:ok, pid} ->
        send(pid, :reconcile_inbox)
        :ok

      error ->
        error
    end
  end
end
