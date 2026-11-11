defmodule Ankole.Issues.Activity do
  @moduledoc """
  Reads the work that is scheduled in the rooms that a Human can open: the
  recurring rules that run for an Agent, and the pending checkbacks.

  Each row names its room, so the browser opens the conversation that owns the
  schedule. An Applet's Job schedules stay with their Applet.
  """

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations

  @doc "Lists the Agents' recurring rules and the pending checkbacks, soonest first."
  def scheduled(%Actor{} = actor) do
    rules =
      Ankole.Schedule.list_cron_schedules()
      |> Enum.filter(&(&1.status in [:active, :paused] and is_nil(&1.owner_job_id)))
      |> Enum.map(fn rule ->
        %{
          kind: "cron",
          id: rule.id,
          title: rule.name,
          status: to_string(rule.status),
          agentUID: rule.agent_uid,
          manageable: rule.human_uid == Actor.uid(actor),
          rooms: rule_rooms(rule),
          schedule: rule.schedule,
          timezone: rule.timezone,
          dueAt: rule.next_fire_at,
          lastFiredAt: rule.last_fire_at
        }
      end)

    checkbacks =
      Ankole.Schedule.list_scheduled_events!(
        query: [filter: [kind: "check_back_later", status: :scheduled], sort: [due_at: :asc]]
      )
      |> Enum.map(fn event ->
        %{
          kind: "checkback",
          id: to_string(event.id),
          title: "",
          status: "scheduled",
          agentUID: event.agent_uid,
          manageable: false,
          rooms: [event.conversation_id || room_id(event.session_id)],
          schedule: nil,
          timezone: event.timezone,
          dueAt: event.due_at,
          lastFiredAt: nil
        }
      end)

    {:ok,
     (rules ++ checkbacks)
     |> in_open_rooms(actor)
     |> named()
     |> Enum.sort_by(&(&1.dueAt || ~U[9999-12-31 00:00:00Z]), DateTime)}
  end

  @doc """
  Pauses, resumes, runs now, or removes a cron rule. A Human manages the rules
  that run on the Human's own authority, such as the rule of an Issue that the
  Human made repeat.
  """
  def change_schedule(%Actor{} = actor, id, change) do
    uid = Actor.uid(actor)

    with {:ok, %{human_uid: ^uid, owner_job_id: nil} = rule} <-
           Ankole.Schedule.get_cron_schedule(id),
         {:ok, _} <- apply_change(rule.id, change) do
      {:ok, rule.id}
    else
      {:ok, _rule} -> {:error, :issue_not_found}
      {:error, :not_found} -> {:error, :issue_not_found}
      {:error, _} = error -> error
    end
  end

  defp apply_change(id, :pause), do: Ankole.Schedule.pause_cron_schedule(id)
  defp apply_change(id, :resume), do: Ankole.Schedule.resume_cron_schedule(id)
  defp apply_change(id, :remove), do: Ankole.Schedule.remove_cron_schedule(id)

  defp apply_change(id, :run),
    do:
      Ankole.Schedule.run_cron_schedule(id,
        idempotency_key: "work-run:" <> Ankole.Ecto.UUIDv7.autogenerate()
      )

  # A rule belongs to the conversation that manages it, or else to a
  # conversation that receives its reports.
  defp rule_rooms(rule) do
    targets =
      for %{"conversation_id" => id} <- get_in(rule.delivery || %{}, ["targets"]) || [], do: id

    [room_id(rule.owner_session_id) | targets]
  end

  defp room_id(session_id) when is_binary(session_id) do
    case Ankole.Sessions.Key.parse(session_id) do
      {:conversation, id} -> id
      _ -> nil
    end
  end

  defp room_id(_session_id), do: nil

  # Keeps the rows with a room that the Human can open, and names that room.
  # `Conversations.list_rooms/2` applies the access rules of the Chat sidebar.
  defp in_open_rooms(rows, actor) do
    ids = rows |> Enum.flat_map(& &1.rooms) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    titles =
      actor
      |> Conversations.list_rooms(ids: ids)
      |> Map.new(&{&1.conversation.id, &1.conversation.title || ""})

    Enum.flat_map(rows, fn row ->
      case Enum.find(row.rooms, &is_map_key(titles, &1)) do
        nil ->
          []

        id ->
          [
            row
            |> Map.delete(:rooms)
            |> Map.merge(%{conversationID: id, conversationTitle: titles[id]})
          ]
      end
    end)
  end

  defp named([]), do: []

  defp named(rows) do
    agents =
      Ankole.Principals.list_principals!(
        query: [filter: [uid: [in: rows |> Enum.map(& &1.agentUID) |> Enum.uniq()]]]
      )
      |> Map.new(&{&1.uid, Ankole.Principals.display_name(&1)})

    Enum.map(rows, &Map.put(&1, :agentName, agents[&1.agentUID] || &1.agentUID))
  end
end
