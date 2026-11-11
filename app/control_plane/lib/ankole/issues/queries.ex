defmodule Ankole.Issues.Queries do
  @moduledoc """
  Reads the Work list of one Human: the Issues whose room the Human takes part
  in, and the rooms in which a Background Agent Job or Workflow is live.

  A work item's status follows its room. It is `waiting` while the Agent needs
  an answer, and `working` while a turn, a Background Agent Job, or a Workflow of
  the room is live. Otherwise the Issue decides: `todo` before the Agent has the
  request, `review` once the Agent has stopped, and `done` after a person
  accepted the result.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Issues.Issue
  alias Ankole.Pod.Chat.Presentation

  @open_limit 1_000
  @done_limit 100
  @live_jobs [:queued, :running, :waiting_on_user]

  @doc "Finds the Issue of a room."
  def fetch(id), do: read(id, & &1)

  @doc "Names the Agent of a room's Issue, or gives `nil` for a room without one."
  def agent_uid(id) do
    case fetch(id) do
      {:ok, issue} -> issue.agent_uid
      {:error, :issue_not_found} -> nil
    end
  end

  @doc "Finds the Issue of a room and locks its row in the caller's transaction."
  def lock(id), do: read(id, &Ash.Query.lock(&1, :for_update))

  defp read(id, prepare) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Issue{} = issue <-
           Issue
           |> Ash.Query.filter(conversation_id == ^id)
           |> prepare.()
           |> Ankole.Ash.read_one!() do
      {:ok, issue}
    else
      _ -> {:error, :issue_not_found}
    end
  end

  defp read(_id, _prepare), do: {:error, :issue_not_found}

  @doc "Tells whether the Human can open the Issue's room."
  def access(%Actor{} = actor, %Issue{} = issue) do
    case Conversations.visible_native_conversation(actor, issue.conversation_id) do
      {:ok, _conversation} -> :ok
      _ -> {:error, :issue_not_found}
    end
  end

  @doc "Reads one Issue as a work item."
  def get(%Actor{} = actor, id) do
    with {:ok, issue} <- fetch(id),
         {jobs, workflows} = live_runs(MapSet.new([issue.conversation_id])),
         [item] <- items(actor, [issue], jobs, workflows) do
      {:ok, item}
    else
      _ -> {:error, :issue_not_found}
    end
  end

  @doc """
  Lists the Human's work items, latest activity first: every open Issue, the
  latest accepted ones, and the rooms without an Issue in which a Background
  Agent Job or Workflow is live.
  """
  def list(%Actor{} = actor) do
    {:ok, joined} = Conversations.participating_ids(Actor.uid(actor))

    open =
      Issue
      |> Ash.Query.filter(conversation_id in ^joined and status != :done)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@open_limit)
      |> Ankole.Ash.read!()

    done =
      Issue
      |> Ash.Query.filter(conversation_id in ^joined and status == :done)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@done_limit)
      |> Ankole.Ash.read!()

    {jobs, workflows} = live_runs(MapSet.new(joined))
    {:ok, items(actor, open ++ done, jobs, workflows)}
  end

  # The live runs whose owner is one of the rooms. A tenant has few live runs,
  # so the status filter selects them and the rooms narrow them here.
  defp live_runs(rooms) do
    fields = [
      :id,
      :agent_uid,
      :owner_session_id,
      :source_signal_id,
      :source_tool_call_id,
      :title,
      :status,
      :inserted_at,
      :updated_at,
      :completed_at
    ]

    jobs =
      Ankole.BackgroundAgentJobs.list_jobs!(
        query: [
          filter: [status: [in: @live_jobs], skill_lesson_reflection?: false],
          select: fields ++ [:continued_from_job_id, :runtime_thread_id, :started_at, :metadata],
          sort: [inserted_at: :desc]
        ]
      )

    workflows =
      Ankole.Workflow.list_runs!(
        query: [filter: [status: :running], select: fields, sort: [inserted_at: :desc]]
      )

    in_rooms = &MapSet.member?(rooms, room_id(&1.owner_session_id))
    {Enum.filter(jobs, in_rooms), Enum.filter(workflows, in_rooms)}
  end

  defp room_id(session_id) do
    case Ankole.Sessions.Key.parse(session_id) do
      {:conversation, id} -> id
      _ -> nil
    end
  end

  defp items(actor, issues, jobs, workflows) do
    runs =
      Presentation.run_summaries(jobs, workflows)
      |> Enum.zip(Enum.map(jobs ++ workflows, &room_id(&1.owner_session_id)))
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))

    issues = Map.new(issues, &{&1.conversation_id, &1})
    ids = Enum.uniq(Map.keys(issues) ++ Map.keys(runs))

    actor
    |> Conversations.list_rooms(ids: ids)
    |> Enum.sort_by(& &1.conversation.last_activity_at, {:desc, DateTime})
    |> Enum.flat_map(fn detail ->
      id = detail.conversation.id
      item(detail, issues[id], Map.get(runs, id, []))
    end)
  end

  defp item(detail, issue, runs) do
    room = Presentation.conversation(detail)

    case status(issue, detail, room.rowStatus, runs) do
      nil ->
        []

      status ->
        [
          %{
            id: room.id,
            title: room.title || "",
            status: status,
            tracked: not is_nil(issue),
            description: if(issue && issue.status == :todo, do: issue.description),
            agent: agent(detail, issue),
            runs: runs,
            lastActivityAt: room.lastActivityAt
          }
        ]
    end
  end

  defp status(issue, detail, row_status, runs) do
    queued? = Enum.any?(detail.agents, &(detail.statuses[&1.uid].state == :queued))

    cond do
      row_status == "waiting_choice" or Enum.any?(runs, &(&1.status == "waiting_on_user")) ->
        :waiting

      runs != [] or queued? or row_status in ["streaming", "running_background"] ->
        :working

      is_nil(issue) ->
        nil

      issue.status == :todo ->
        :todo

      issue.status == :started ->
        :review

      issue.status == :done ->
        :done
    end
  end

  # The Agent that the Issue names, or the room's Agent when the room has no Issue.
  defp agent(detail, issue) do
    named = issue && detail.member_principals[issue.agent_uid]

    case named || detail.agent do
      nil -> nil
      principal -> %{uid: principal.uid, name: detail.member_names[principal.uid]}
    end
  end
end
