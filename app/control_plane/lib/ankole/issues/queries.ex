defmodule Ankole.Issues.Queries do
  @moduledoc """
  Reads the Work list of one Human: the Issues whose room the Human takes part
  in, and the rooms in which a Background Agent Job or Workflow is live.

  A work item's status follows its room. It is `waiting` while the Agent needs
  an answer, and `working` while a turn, a Background Agent Job, or a Workflow of
  the room is live, or while a cron rule that the room owns runs. Otherwise the
  Issue decides: `todo` before the Agent has the request, `review` once the
  Agent has stopped, and `done` after a person accepted the result.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Issues.Issue
  alias Ankole.Pod.Chat.Presentation
  alias Ankole.Sessions.Key

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
  def lock(id), do: read(id, &Ash.Query.lock(&1, :for_update), lock?: true)

  defp read(id, prepare, opts \\ [])

  defp read(id, prepare, opts) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         read_opts <- if(opts[:lock?], do: [lock_identity: {"issues", id}], else: []),
         %Issue{} = issue <-
           Issue
           |> Ash.Query.filter(conversation_id == ^id)
           |> prepare.()
           |> Ankole.Ash.read_one!(read_opts) do
      {:ok, issue}
    else
      _ -> {:error, :issue_not_found}
    end
  end

  defp read(_id, _prepare, _opts), do: {:error, :issue_not_found}

  @doc """
  Finds the cron rule that repeats an Issue: the rule that Work created for the
  Issue's room, while it is active or paused.
  """
  def rule(id) do
    session = Key.conversation(id)

    Ankole.Schedule.list_cron_schedules(nil, session)
    |> Enum.find(&(&1.idempotency_key == id and &1.status in [:active, :paused]))
  end

  @doc "Tells whether a run that a person asked of the cron rule waits to fire."
  def pending_run?(rule_id) do
    Ankole.Schedule.list_scheduled_events!(
      query: [filter: [cron_schedule_id: rule_id, status: :scheduled], select: [:id], limit: 1]
    ) != []
  end

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
         visible_parents <- visible_parent_ids(actor, issue),
         [item] <- items(actor, [issue], MapSet.new([issue.conversation_id]), visible_parents) do
      {:ok, item}
    else
      _ -> {:error, :issue_not_found}
    end
  end

  defp visible_parent_ids(_actor, %Issue{parent_id: nil}), do: []

  defp visible_parent_ids(actor, %Issue{parent_id: parent_id}) do
    case Conversations.visible_native_conversation(actor, parent_id) do
      {:ok, _conversation} -> [parent_id]
      _ -> []
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

    {:ok, items(actor, open ++ done, MapSet.new(joined), joined)}
  end

  defp items(actor, issues, rooms, joined) do
    rules = rules(rooms)
    {jobs, workflows} = live_runs(rooms, rules)

    runs =
      Presentation.run_summaries(jobs, workflows)
      |> Enum.zip(Enum.map(jobs ++ workflows, &owner_room(&1.owner_session_id, rules)))
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))

    issues = Map.new(issues, &{&1.conversation_id, &1})
    ids = Enum.uniq(Map.keys(issues) ++ Map.keys(runs))
    context = context(Map.values(issues), rules, joined) |> Map.put(:uid, Actor.uid(actor))

    actor
    |> Conversations.list_rooms(ids: ids)
    |> Enum.sort_by(& &1.conversation.last_activity_at, {:desc, DateTime})
    |> Enum.flat_map(fn detail ->
      id = detail.conversation.id
      item(detail, issues[id], Map.get(runs, id, []), context)
    end)
  end

  # The cron rules that the rooms own, by the rule's execution Session.
  defp rules(rooms) do
    rooms
    |> Enum.map(&Key.conversation/1)
    |> Ankole.Schedule.list_room_cron_schedules()
    |> Map.new(&{Ankole.Schedule.cron_execution_session_id(&1.id), &1})
  end

  # The live runs whose owner is one of the rooms or a cron rule of one.
  defp live_runs(rooms, rules) do
    owner_sessions = Enum.map(rooms, &Key.conversation/1) ++ Map.keys(rules)

    if owner_sessions == [] do
      {[], []}
    else
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
            filter: [
              status: [in: @live_jobs],
              skill_lesson_reflection?: false,
              owner_session_id: [in: owner_sessions]
            ],
            select:
              fields ++ [:continued_from_job_id, :runtime_thread_id, :started_at, :metadata],
            sort: [inserted_at: :desc]
          ]
        )

      workflows =
        Ankole.Workflow.list_runs!(
          query: [
            filter: [status: :running, owner_session_id: [in: owner_sessions]],
            select: fields,
            sort: [inserted_at: :desc]
          ]
        )

      {jobs, workflows}
    end
  end

  defp owner_room("cron:" <> _ = session_id, rules),
    do: rules[session_id] && room_id(rules[session_id].owner_session_id)

  defp owner_room(session_id, _rules), do: room_id(session_id)

  defp room_id(session_id) do
    case Key.parse(session_id) do
      {:conversation, id} -> id
      _ -> nil
    end
  end

  # What the work items need beyond their rooms: which rooms' cron rules run,
  # the repeating rule of each Issue, sub-Issue counts, parent titles, and the
  # names in the Squads.
  defp context(issues, rules, joined) do
    sessions = Map.new(rules, fn {session, rule} -> {{rule.agent_uid, session}, rule} end)
    statuses = Ankole.Sessions.statuses(Map.keys(sessions))

    pending =
      case Map.values(rules) do
        [] ->
          MapSet.new()

        listed ->
          Ankole.Schedule.list_scheduled_events!(
            query: [
              filter: [cron_schedule_id: [in: Enum.map(listed, & &1.id)], status: :scheduled],
              select: [:cron_schedule_id]
            ]
          )
          |> MapSet.new(& &1.cron_schedule_id)
      end

    running =
      for {key, rule} <- sessions,
          statuses[key].state != :idle or MapSet.member?(pending, rule.id),
          into: MapSet.new(),
          do: room_id(rule.owner_session_id)

    repeats =
      for {_session, rule} <- rules,
          rule.idempotency_key == room_id(rule.owner_session_id),
          into: %{},
          do: {rule.idempotency_key, rule}

    ids = Enum.map(issues, & &1.conversation_id)

    children =
      Issue
      |> Ash.Query.filter(parent_id in ^ids)
      |> Ash.Query.select([:parent_id, :status])
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.parent_id, & &1.status)

    joined = MapSet.new(joined)

    parents =
      issues
      |> Enum.map(& &1.parent_id)
      |> Enum.filter(&(&1 && MapSet.member?(joined, &1)))
      |> Enum.uniq()
      |> titles()

    squads = issues |> Enum.flat_map(& &1.squad_uids) |> Enum.uniq() |> names()

    %{
      running: running,
      repeats: repeats,
      children: children,
      parents: parents,
      squads: squads
    }
  end

  defp titles([]), do: %{}

  defp titles(ids) do
    Conversations.list_conversations!(query: [filter: [id: [in: ids]], select: [:id, :title]])
    |> Map.new(&{&1.id, &1.title || ""})
  end

  defp names([]), do: %{}

  defp names(uids) do
    Ankole.Principals.list_principals!(query: [filter: [uid: [in: uids], status: :active]])
    |> Map.new(&{&1.uid, Ankole.Principals.display_name(&1)})
  end

  defp item(detail, issue, runs, context) do
    room = Presentation.conversation(detail)
    running? = MapSet.member?(context.running, room.id)

    case status(issue, detail, room.rowStatus, runs, running?) do
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
            labels: (issue && issue.labels) || [],
            parent: parent(issue, context.parents),
            children: children(issue, context.children),
            squad: squad(issue, context.squads),
            repeat: repeat(context.repeats[room.id], context.uid),
            lastActivityAt: room.lastActivityAt
          }
        ]
    end
  end

  defp status(issue, detail, row_status, runs, running?) do
    queued? = Enum.any?(detail.agents, &(detail.statuses[&1.uid].state == :queued))

    cond do
      row_status == "waiting_choice" or Enum.any?(runs, &(&1.status == "waiting_on_user")) ->
        :waiting

      runs != [] or queued? or running? or row_status in ["streaming", "running_background"] ->
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

  # A parent shows only while the Human can open its room.
  defp parent(%Issue{parent_id: id}, titles) when is_map_key(titles, id),
    do: %{id: id, title: titles[id]}

  defp parent(_issue, _titles), do: nil

  defp children(%Issue{conversation_id: id}, children) when is_map_key(children, id) do
    statuses = children[id]
    %{total: length(statuses), done: Enum.count(statuses, &(&1 == :done))}
  end

  defp children(_issue, _children), do: nil

  defp squad(%Issue{squad_uids: uids}, names),
    do: for(uid <- uids, is_map_key(names, uid), do: %{uid: uid, name: names[uid]})

  defp squad(_issue, _names), do: []

  defp repeat(nil, _uid), do: nil

  # The Human whose authority the rule runs on manages it.
  defp repeat(rule, uid) do
    %{
      id: rule.id,
      status: rule.status,
      manageable: rule.human_uid == uid,
      expression: rule.schedule["expression"],
      timezone: rule.timezone,
      dueAt: rule.next_fire_at
    }
  end
end
