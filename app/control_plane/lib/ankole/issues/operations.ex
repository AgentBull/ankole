defmodule Ankole.Issues.Operations do
  @moduledoc """
  Creates and changes Issues. Each Issue has one room in `Ankole.Conversations`,
  and its Agent works in its Session of that room.

  Starting an Issue posts the request as the starter's message to the Agent, so
  the Agent receives it through the room's ordinary message intake. An Issue in
  `todo` has sent nothing yet.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Issues.{Issue, Queries}
  alias Ankole.Repo

  @title_limit 200

  @doc """
  Creates an Issue and its room for a Human. The Agent starts at once unless
  `start` is false.
  """
  def create(%Actor{} = actor, attrs) when is_map(attrs) do
    Repo.transact_top_level(fn -> create_in_tx(actor, attrs) end, after_commit: &publish/1)
    |> projected(actor)
  end

  defp create_in_tx(actor, attrs) do
    id = Ankole.Ecto.UUIDv7.autogenerate()

    with {:ok, title} <- title(attrs[:title]),
         {:ok, agent_uid} <- agent(attrs[:agent_uid]),
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
             agent_uid: agent_uid
           }) do
      if attrs[:start] == false,
        do: {:ok, %{issue: issue, posted: nil}},
        else: start_in_tx(actor, issue, title)
    end
  end

  @doc """
  Changes an Issue for a Human who can open its room. `description` changes the
  request of an Issue in `todo`. `status` starts a `todo` Issue, accepts the
  result with `done`, or reopens a `done` Issue with `started`.
  """
  def update(%Actor{} = actor, id, attrs) when is_map(attrs) do
    with {:ok, issue} <- Queries.fetch(id),
         :ok <- Queries.access(actor, issue) do
      Repo.transact_top_level(fn -> update_in_tx(actor, issue.conversation_id, attrs) end,
        after_commit: &publish/1
      )
      |> projected(actor)
    end
  end

  # The row lock comes first, as it does when a run starts in the room, and
  # makes a second start read the Issue that the first one already started.
  defp update_in_tx(actor, id, attrs) do
    with {:ok, issue} <- Queries.lock(id),
         {:ok, issue} <- describe(issue, attrs[:description]),
         do: move(actor, issue, attrs[:status])
  end

  defp describe(issue, nil), do: {:ok, issue}

  # After the start, the request is the room's first message.
  defp describe(%Issue{status: :todo} = issue, text) when is_binary(text) do
    case issue |> selected() |> Ankole.Ash.update_where(:describe, %{description: text}) do
      {:ok, [changed]} -> {:ok, changed}
      {:ok, []} -> {:error, :invalid_issue}
      {:error, _} = error -> error
    end
  end

  defp describe(_issue, _text), do: {:error, :invalid_issue}

  defp move(_actor, issue, nil), do: {:ok, %{issue: issue, posted: nil}}
  defp move(_actor, %Issue{status: status} = issue, status), do: move(nil, issue, nil)

  defp move(actor, %Issue{status: :todo} = issue, :started),
    do: start_in_tx(actor, issue, room_title(issue.conversation_id))

  defp move(_actor, %Issue{status: :done} = issue, :started),
    do: transition(issue, if(requested?(issue), do: :start, else: :wait))

  defp move(_actor, issue, :done), do: transition(issue, :finish)
  defp move(_actor, _issue, _status), do: {:error, :invalid_issue}

  defp start_in_tx(actor, issue, title) do
    with {:ok, posted} <-
           Conversations.post_in_tx(actor, issue.conversation_id, %{
             message_id: Ankole.Ecto.UUIDv7.autogenerate(),
             text: request(title, issue.description),
             target_agent_uid: issue.agent_uid
           }),
         {:ok, result} <- transition(issue, :start),
         do: {:ok, %{result | posted: posted}}
  end

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

  @doc """
  Tracks the Background Agent Job or Workflow that starts in a room, in the
  caller's transaction. A run reopens the room's Issue that a person had
  accepted, and leaves an Issue in `todo` alone, because its request has not
  been sent. A personal assistant's task room without an Issue receives one, so
  the assistant's background work appears in Work.
  """
  def ensure_for_task_room_in_tx(agent_uid, owner_session_id)
      when is_binary(agent_uid) and is_binary(owner_session_id) do
    with {:conversation, id} <- Ankole.Sessions.Key.parse(owner_session_id) do
      case Queries.fetch(id) do
        {:ok, %Issue{status: :done} = issue} ->
          with {:ok, _} <- transition(issue, :start), do: :ok

        {:ok, _issue} ->
          :ok

        {:error, :issue_not_found} ->
          open_for_assistant_task(agent_uid, id)
      end
    else
      _ -> :ok
    end
  end

  def ensure_for_task_room_in_tx(_agent_uid, _owner_session_id), do: :ok

  defp open_for_assistant_task(agent_uid, id) do
    with {:ok, %{kind: :native, native_access_scope: :participants, room_mode: :dm}} <-
           Conversations.get_conversation(id),
         %{type: :personal_assistant} <- Ankole.Principals.get_agent_record!(agent_uid),
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

  defp room_title(id) do
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
    title = value |> Ankole.Files.Path.strip_bidi_and_controls() |> String.trim()

    if title != "" and String.length(title) <= @title_limit,
      do: {:ok, title},
      else: {:error, :invalid_issue}
  end

  defp title(_value), do: {:error, :invalid_issue}

  defp agent(uid) when is_binary(uid) and uid != "", do: {:ok, uid}
  defp agent(_uid), do: {:error, :invalid_issue}
end
