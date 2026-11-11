defmodule Ankole.Issues.Operations do
  @moduledoc """
  Creates and changes Issues. Each Issue has one room in `Ankole.Conversations`,
  and its Agent works in its Session of that room.

  Starting an Issue posts the request as the starter's message to the Agent, so
  the Agent receives it through the room's ordinary message intake. An Issue in
  `todo` has sent nothing yet. An Issue that repeats owns a cron rule in
  `Ankole.Schedule`, whose fires run the request in the rule's own Session and
  report to the Issue's room.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Issues.{Issue, Queries}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo
  alias Ankole.Sessions.Key

  @title_limit 200
  @label_limit 40
  @report_limit 4_000

  @doc """
  Creates an Issue and its room for a Human. The Agent starts at once unless
  `start` is false. With `repeat`, the Issue runs its request on that cron
  schedule, and a start runs it once now.
  """
  def create(%Actor{} = actor, attrs) when is_map(attrs) do
    with {:ok, repeat} <- repeat(attrs[:repeat]) do
      Repo.transact_top_level(fn -> create_in_tx(actor, attrs, repeat) end,
        after_commit: &publish/1
      )
      |> schedule(actor, repeat, attrs[:start] != false)
      |> projected(actor)
    end
  end

  defp create_in_tx(actor, attrs, repeat) do
    id = Ankole.Ecto.UUIDv7.autogenerate()

    with {:ok, title} <- title(attrs[:title]),
         {:ok, agent_uid} <- agent(attrs[:agent_uid]),
         {:ok, labels} <- labels(attrs[:labels]),
         {:ok, parent_id} <- parent(actor, attrs[:parent_id]),
         {:ok, squad} <- squad(actor, agent_uid, attrs[:squad_uids]),
         {:ok, _room} <-
           Conversations.ensure_issue_room_in_tx(actor, %{
             conversation_id: id,
             title: title,
             agent_uid: agent_uid
           }),
         {:ok, issue} <-
           Ankole.Ash.create(Issue, :open, %{
             conversation_id: id,
             status: :todo,
             description: attrs[:description] || "",
             agent_uid: agent_uid,
             labels: labels,
             parent_id: parent_id,
             squad_uids: squad
           }) do
      # A repeating Issue runs in its rule's Session, so its room receives no request message.
      begin_in_tx(actor, issue, title, attrs[:start] != false and is_nil(repeat))
    end
  end

  defp begin_in_tx(actor, issue, title, true) do
    with {:ok, result} <- start_in_tx(actor, issue, title),
         do: {:ok, Map.put(result, :title, title)}
  end

  defp begin_in_tx(_actor, issue, title, false),
    do: {:ok, %{issue: issue, posted: nil, title: title}}

  # The rule lives in Schedule, whose writes take their locks before a room's, so
  # it commits after the room. A failure leaves an ordinary Issue that waits.
  defp schedule({:ok, %{issue: issue, title: title}} = result, actor, repeat, start?)
       when is_map(repeat) do
    attrs = %{
      agent_uid: issue.agent_uid,
      owner_session_id: Key.conversation(issue.conversation_id),
      name: title,
      idempotency_key: issue.conversation_id,
      schedule: Map.put(repeat, "kind", "cron"),
      delivery: %{"targets" => [%{"conversation_id" => issue.conversation_id}]},
      payload: %{"task" => request(title, issue.description)}
    }

    with {:ok, %{cron_schedule: rule}} <-
           Ankole.Schedule.create_cron_schedule(attrs,
             authorization: WorkAccess.from_sender(Actor.uid(actor)),
             created_by: %{
               "kind" => "pod_work",
               "principal_uid" =>
                 actor.principal |> Ankole.ActorRef.from_principal() |> to_string()
             }
           ),
         {:ok, _run} <-
           if(start?,
             do: run_rule(rule.id, &Ankole.Schedule.run_cron_schedule/2),
             else: {:ok, nil}
           ) do
      result
    end
  end

  defp schedule(result, _actor, _repeat, _start?), do: result

  @doc """
  Changes an Issue for a Human who can open its room. `description` changes the
  request of an Issue in `todo`, and `labels` replaces its labels. `status`
  starts a `todo` Issue, accepts the result with `done`, or reopens a `done`
  Issue with `started`. Accepting a sub-Issue reports its result in the parent's
  room, where the parent's Agent continues.
  """
  def update(%Actor{} = actor, id, attrs) when is_map(attrs) do
    with {:ok, issue} <- Queries.fetch(id),
         :ok <- Queries.access(actor, issue),
         {:ok, result} <-
           Repo.transact_top_level(fn -> update_in_tx(actor, issue.conversation_id, attrs) end,
             after_commit: &publish/1
           ) do
      if issue.status != :done and result.issue.status == :done, do: report(actor, result.issue)
      projected({:ok, result}, actor)
    end
  end

  # The row lock comes first, as it does when a run starts in the room, and
  # makes a second start read the Issue that the first one already started.
  defp update_in_tx(actor, id, attrs) do
    with {:ok, issue} <- Queries.lock(id),
         {:ok, issue} <- describe(issue, attrs[:description]),
         {:ok, issue} <- label(issue, attrs[:labels]),
         do: move(actor, issue, attrs[:status])
  end

  defp describe(issue, nil), do: {:ok, issue}

  # After the start, the request is the room's first message.
  defp describe(%Issue{status: :todo} = issue, text) when is_binary(text) do
    with {:ok, changed} <- change(issue, :describe, %{description: text}),
         :ok <- sync_rule_task(changed),
         do: {:ok, changed}
  end

  defp describe(_issue, _text), do: {:error, :invalid_issue}

  defp label(issue, nil), do: {:ok, issue}

  defp label(issue, values) do
    with {:ok, labels} <- labels(values), do: change(issue, :label, %{labels: labels})
  end

  defp change(issue, action, input) do
    case issue |> selected() |> Ankole.Ash.update_where(action, input) do
      {:ok, [changed]} -> {:ok, changed}
      {:ok, []} -> {:error, :invalid_issue}
      {:error, _} = error -> error
    end
  end

  # A repeating Issue that waits keeps its rule's task equal to its request.
  defp sync_rule_task(issue) do
    case Queries.rule(issue.conversation_id) do
      nil ->
        :ok

      rule ->
        payload =
          Map.put(rule.payload || %{}, "task", request(room_title(issue), issue.description))

        with {:ok, _rule} <-
               Ankole.Schedule.Cron.update_cron_schedule_in_tx(rule.id, %{payload: payload}, []),
             do: :ok
    end
  end

  defp move(_actor, issue, nil), do: {:ok, %{issue: issue, posted: nil}}
  defp move(_actor, %Issue{status: status} = issue, status), do: move(nil, issue, nil)

  defp move(actor, %Issue{status: :todo} = issue, :started) do
    case Queries.rule(issue.conversation_id) do
      nil -> start_in_tx(actor, issue, room_title(issue))
      rule -> run_rule_in_tx(issue, rule)
    end
  end

  defp move(_actor, %Issue{status: :done} = issue, :started),
    do: transition(issue, if(requested?(issue), do: :start, else: :wait))

  defp move(_actor, issue, :done), do: transition(issue, :finish)
  defp move(_actor, _issue, _status), do: {:error, :invalid_issue}

  defp start_in_tx(actor, issue, title) do
    with {:ok, posted} <-
           Conversations.post_in_tx(actor, issue.conversation_id, %{
             message_id: Ankole.Ecto.UUIDv7.autogenerate(),
             text: request(title, issue.description),
             target_agent_uid: issue.agent_uid,
             mentions: Enum.map(issue.squad_uids, &%{type: :agent, uid: &1})
           }),
         {:ok, result} <- transition(issue, :start),
         do: {:ok, %{result | posted: posted}}
  end

  # A repeating Issue starts with one run of its rule, and the fire marks it
  # started. Until then the pending run shows the Issue as working, and a second
  # start finds that run instead of arming another.
  defp run_rule_in_tx(issue, rule) do
    with false <- Queries.pending_run?(rule.id),
         {:ok, _run} <- run_rule(rule.id, &Ankole.Schedule.Cron.run_cron_schedule_in_tx/2) do
      {:ok, %{issue: issue, posted: nil}}
    else
      true -> {:ok, %{issue: issue, posted: nil}}
      error -> error
    end
  end

  defp run_rule(id, run),
    do: run.(id, idempotency_key: "issue-start:" <> Ankole.Ecto.UUIDv7.autogenerate())

  # The title names the work; the description, when a person wrote one, says how.
  defp request(title, description) do
    if String.trim(description) == "", do: title, else: title <> "\n\n" <> description
  end

  defp transition(issue, action) do
    case issue |> selected() |> Ankole.Ash.update_where(action) do
      {:ok, [changed]} -> {:ok, %{issue: changed, posted: nil}}
      {:ok, []} -> {:ok, %{issue: issue, posted: nil}}
      {:error, _} = error -> error
    end
  end

  defp selected(issue), do: Ash.Query.filter(Issue, conversation_id == ^issue.conversation_id)

  # The Agent has the request, or anything else to go on, once the room holds a message.
  defp requested?(issue) do
    Conversations.list_messages!(
      query: [
        filter: [conversation_id: issue.conversation_id, kind: :message],
        select: [:id],
        limit: 1
      ]
    ) != []
  end

  # The parent's Agent learns of an accepted sub-Issue as a message from the
  # person who accepted it. The report is best effort: the acceptance stands
  # when the person cannot write in the parent's room.
  defp report(actor, %Issue{parent_id: parent_id} = issue) when is_binary(parent_id) do
    with {:ok, %Issue{status: :started} = parent} <- Queries.fetch(parent_id),
         :ok <- Queries.access(actor, parent) do
      Repo.transact_top_level(
        fn ->
          Conversations.post_in_tx(actor, parent_id, %{
            message_id: Ankole.Ecto.UUIDv7.autogenerate(),
            text: report_text(issue),
            target_agent_uid: parent.agent_uid
          })
        end,
        after_commit: &Conversations.publish_native_change/1
      )
    end

    :ok
  end

  defp report(_actor, _issue), do: :ok

  defp report_text(issue) do
    reply =
      Conversations.list_messages!(
        query: [
          filter: [conversation_id: issue.conversation_id, kind: :message, author_type: :agent],
          sort: [seq: :desc],
          select: [:text],
          limit: 1
        ]
      )
      |> Enum.map_join(& &1.text)
      |> String.slice(0, @report_limit)

    Ankole.I18n.t("pod.work.sub_issue_accepted", %{"title" => room_title(issue)}) <>
      if(reply == "", do: "", else: "\n\n" <> quoted(reply))
  end

  defp quoted(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))

  @doc """
  Tracks the Background Agent Job or Workflow that starts in a room, in the
  caller's transaction. A run reopens the room's Issue that a person had
  accepted, and leaves an Issue in `todo` alone, because its request has not
  been sent. A room of the Chat list without an Issue receives one, so the
  background work that starts in a conversation appears in Work. A run that a
  repeating Issue's fire starts reopens that Issue.
  """
  def ensure_for_task_room_in_tx(agent_uid, owner_session_id)
      when is_binary(agent_uid) and is_binary(owner_session_id) do
    case Key.parse(owner_session_id) do
      {:conversation, id} ->
        case Queries.fetch(id) do
          {:ok, %Issue{status: :done} = issue} ->
            with {:ok, _} <- transition(issue, :start), do: :ok

          {:ok, _issue} ->
            :ok

          {:error, :issue_not_found} ->
            open_for_room(agent_uid, id)
        end

      {:cron, rule_id} ->
        rule_id |> Ankole.Schedule.get_cron_schedule() |> track_fire()

      _ ->
        :ok
    end
  end

  def ensure_for_task_room_in_tx(_agent_uid, _owner_session_id), do: :ok

  @doc """
  Marks the Issue of a cron rule's room as started when the rule fires, in the
  fire's transaction. A fire is a run of the request, so it starts an Issue that
  waits and reopens an accepted one.
  """
  def track_fire_in_tx(rule), do: track_fire({:ok, rule})

  defp track_fire({:ok, %{agent_uid: agent_uid, owner_session_id: session_id}})
       when is_binary(agent_uid) and is_binary(session_id) do
    with {:conversation, id} <- Key.parse(session_id),
         {:ok, %Issue{status: status} = issue} when status != :started <- Queries.fetch(id),
         {:ok, _} <- transition(issue, :start) do
      :ok
    else
      {:error, error} when is_exception(error) -> {:error, error}
      _ -> :ok
    end
  end

  defp track_fire(_rule), do: :ok

  # The room of a personal assistant's task, of a direct conversation with an
  # AI colleague, or of a group in the Chat list.
  defp open_for_room(agent_uid, id) do
    with {:ok, %{kind: :native, native_access_scope: :participants}} <-
           Conversations.get_conversation(id),
         {:ok, _issue, _} <-
           Ankole.Ash.insert_if_absent(Issue, :ensure, %{
             conversation_id: id,
             status: :started,
             agent_uid: agent_uid
           }) do
      :ok
    else
      {:error, error} when is_exception(error) -> {:error, error}
      _ -> :ok
    end
  end

  defp room_title(%Issue{conversation_id: id}) do
    case Conversations.get_conversation(id) do
      {:ok, %{title: title}} when is_binary(title) -> title
      _ -> ""
    end
  end

  # `Repo.transact_top_level/2` calls this with the committed transaction's value.
  defp publish(%{issue: issue, posted: posted}) do
    if posted, do: Conversations.publish_native_change(posted)
    Conversations.Events.publish_committed([{issue.conversation_id, :status}])
  end

  defp projected({:ok, %{issue: issue}}, actor), do: Queries.get(actor, issue.conversation_id)
  defp projected(error, _actor), do: error

  defp title(value) when is_binary(value) do
    title = clean(value)

    if title != "" and String.length(title) <= @title_limit,
      do: {:ok, title},
      else: {:error, :invalid_issue}
  end

  defp title(_value), do: {:error, :invalid_issue}

  defp agent(uid) when is_binary(uid) and uid != "", do: {:ok, uid}
  defp agent(_uid), do: {:error, :invalid_issue}

  defp labels(nil), do: {:ok, []}

  defp labels(values) when is_list(values) do
    labels = values |> Enum.map(&clean/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if length(labels) <= 10 and Enum.all?(labels, &(String.length(&1) <= @label_limit)),
      do: {:ok, labels},
      else: {:error, :invalid_issue}
  end

  defp labels(_values), do: {:error, :invalid_issue}

  defp clean(value) when is_binary(value),
    do: value |> Ankole.Files.Path.strip_bidi_and_controls() |> String.trim()

  defp clean(_value), do: ""

  # A sub-Issue belongs to an Issue that its creator can open.
  defp parent(_actor, nil), do: {:ok, nil}

  defp parent(actor, id) do
    with {:ok, issue} <- Queries.fetch(id),
         :ok <- Queries.access(actor, issue) do
      {:ok, issue.conversation_id}
    else
      _ -> {:error, :invalid_issue}
    end
  end

  # A Squad is the AI colleagues among whom a personal assistant shares the
  # work, because only a personal assistant hands work to colleagues.
  defp squad(_actor, _agent_uid, nil), do: {:ok, []}
  defp squad(_actor, _agent_uid, []), do: {:ok, []}

  defp squad(actor, agent_uid, uids) when is_list(uids) do
    uids = Enum.uniq(uids)

    with {:ok, %{type: :personal_assistant}} <- Ankole.Principals.get_agent_record(agent_uid),
         true <- length(uids) <= 10,
         true <- Enum.all?(uids, &colleague?(actor, &1)) do
      {:ok, uids}
    else
      _ -> {:error, :invalid_issue}
    end
  end

  defp squad(_actor, _agent_uid, _uids), do: {:error, :invalid_issue}

  defp colleague?(actor, uid) do
    match?({:ok, %{type: :ai_colleague}}, Ankole.Principals.get_agent_record(uid)) and
      Conversations.authorize_agent(actor, uid) == :ok
  end

  # Work offers fixed cron expressions in the creator's time zone; Schedule
  # validates both when it creates the rule.
  defp repeat(nil), do: {:ok, nil}

  defp repeat(%{expression: expression, timezone: timezone})
       when is_binary(expression) and is_binary(timezone),
       do: {:ok, %{"expression" => expression, "timezone" => timezone}}

  defp repeat(_repeat), do: {:error, :invalid_issue}
end
