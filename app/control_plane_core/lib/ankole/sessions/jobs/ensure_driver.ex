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

  import Ecto.Query

  def enqueue(key, due_at \\ DateTime.utc_now(:microsecond)) do
    Ankole.Repo.transact(fn repo ->
      insert_due(repo, key, due_at || DateTime.utc_now(:microsecond))
    end)
  end

  def enqueue_in_tx(repo, key, due_at) do
    with {:ok, _} <- insert_due(repo, key, due_at || DateTime.utc_now(:microsecond)), do: :ok
  end

  defp insert_due(repo, key, due_at) do
    with {:ok, job} <- Oban.insert(new(key, scheduled_at: due_at)) do
      # A later input cannot postpone an earlier committed wakeup.
      if job.id do
        repo.update_all(
          from(j in Oban.Job,
            where: j.id == ^job.id and j.state == "scheduled" and j.scheduled_at > ^due_at
          ),
          set: [scheduled_at: due_at]
        )
      end

      {:ok, job}
    end
  end

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
