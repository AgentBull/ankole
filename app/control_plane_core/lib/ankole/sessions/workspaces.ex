defmodule Ankole.Sessions.Workspaces do
  @moduledoc """
  Owns stable numeric Agent Home workspace IDs for Sessions.

  Allocation uses the Session advisory lock. Repeated calls for the same
  `{agent_uid, session_id}` return the same PostgreSQL-owned identity.
  """

  import Ecto.Query, only: [from: 2, where: 3]
  require Ash.Query

  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.SessionWorkspace

  @type result :: {:ok, SessionWorkspace.t()} | {:error, term()}

  @doc false
  @spec ensure_in_tx(module(), String.t(), String.t()) :: result()
  def ensure_in_tx(repo, agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    with {:ok, identity} <- identity(session_id),
         :ok <- lock_owner_in_tx(repo, agent_uid, identity),
         :ok <- Queue.lock_session_in_tx(repo, agent_uid, session_id) do
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

  defp lock_owner_in_tx(_repo, _agent_uid, %{kind: :named}), do: :ok

  defp lock_owner_in_tx(repo, agent_uid, %{kind: kind} = identity) do
    {resource, field} =
      case kind do
        :conversation -> {Ankole.Conversations.Conversation, :conversation_id}
        :background_job -> {Ankole.BackgroundAgentJobs.Schemas.Job, :background_job_id}
        :workflow_task -> {Ankole.Workflow.Schemas.AgentCall, :workflow_agent_call_id}
        :cron -> {Ankole.Schedule.Schemas.CronSchedule, :cron_schedule_id}
      end

    id = Map.fetch!(identity, field)

    query =
      from(owner in resource, where: owner.id == ^id, select: owner.id, lock: "FOR KEY SHARE")

    query =
      if kind == :conversation,
        do: query,
        else: where(query, [owner], owner.agent_uid == ^agent_uid)

    case repo.one(query, lock_identity: {resource.__schema__(:source), id}) do
      nil -> {:error, :session_owner_not_found}
      _id -> :ok
    end
  end
end
