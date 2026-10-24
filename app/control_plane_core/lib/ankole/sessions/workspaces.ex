defmodule Ankole.Sessions.Workspaces do
  @moduledoc """
  Owns stable numeric Agent Home workspace IDs for Sessions.

  Allocation uses the Session advisory lock. Repeated calls for the same
  `{agent_uid, session_id}` return the same PostgreSQL-owned identity.
  """

  require Ash.Query

  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.SessionWorkspace

  @type result :: {:ok, SessionWorkspace.t()} | {:error, term()}

  @doc false
  @spec ensure_in_tx(String.t(), String.t()) :: result()
  def ensure_in_tx(agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    with {:ok, identity} <- identity(session_id),
         :ok <- lock_owner_in_tx(agent_uid, identity),
         :ok <- Queue.lock_session_in_tx(agent_uid, session_id) do
      query =
        SessionWorkspace
        |> Ash.Query.filter(agent_uid == ^agent_uid and session_id == ^session_id)

      case Ankole.Ash.read_one(query) do
        {:ok, %SessionWorkspace{} = workspace} ->
          {:ok, workspace}

        {:ok, nil} ->
          Ankole.Ash.create(SessionWorkspace, :allocate, Map.put(identity, :agent_uid, agent_uid))

        {:error, _} = error ->
          error
      end
    end
  end

  defp identity(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:conversation, id} ->
        {:ok, %{kind: :conversation, conversation_id: id}}

      {:job, id} ->
        integer_identity(:background_job, :background_job_id, id)

      {:workflow_task, id} ->
        integer_identity(:workflow_task, :workflow_agent_call_id, id)

      {:cron, id} ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> {:ok, %{kind: :cron, cron_schedule_id: id}}
          :error -> {:error, :invalid_session_key}
        end

      {:named, name} ->
        {:ok, %{kind: :named, name: name}}

      :error ->
        {:error, :invalid_session_key}
    end
  end

  defp integer_identity(kind, field, id) do
    case Ankole.ModelIntegerID.parse(id) do
      {:ok, id} -> {:ok, %{field => id, kind: kind}}
      :error -> {:error, :invalid_session_key}
    end
  end

  defp lock_owner_in_tx(_agent_uid, %{kind: :named}), do: :ok

  # The owner row keeps its key while the workspace exists. Each owner domain
  # reads its row; the lock identity keeps the work lock order.
  defp lock_owner_in_tx(agent_uid, %{kind: kind} = identity) do
    owner =
      case kind do
        :conversation ->
          Ankole.Conversations.get_conversation!(identity.conversation_id,
            query: key_share()
          )

        :background_job ->
          locked_owner("background_agent_jobs", identity.background_job_id, fn query ->
            filter = [id: identity.background_job_id, agent_uid: agent_uid]
            List.first(Ankole.BackgroundAgentJobs.list_jobs!(query: [{:filter, filter} | query]))
          end)

        :workflow_task ->
          locked_owner("workflow_agent_calls", identity.workflow_agent_call_id, fn query ->
            Ankole.Workflow.get_agent_call!(identity.workflow_agent_call_id,
              query: [{:filter, [agent_uid: agent_uid]} | query]
            )
          end)

        :cron ->
          locked_owner("cron_schedules", identity.cron_schedule_id, fn query ->
            Ankole.Schedule.get_cron_schedule_record!(identity.cron_schedule_id,
              query: [{:filter, [agent_uid: agent_uid]} | query]
            )
          end)
      end

    if owner, do: :ok, else: {:error, :session_owner_not_found}
  end

  defp locked_owner(table, id, read),
    do: Ankole.LockOrder.with_identity({table, id}, fn -> read.(key_share()) end)

  defp key_share, do: [lock: "FOR KEY SHARE", select: [:id]]
end
