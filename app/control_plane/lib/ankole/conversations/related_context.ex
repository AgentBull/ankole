defmodule Ankole.Conversations.RelatedContext do
  @moduledoc "Finds prior work that every Human in the current conversation may read."
  require Ash.Query
  alias Ankole.{Conversations, Principals}
  alias Ankole.Conversations.{Conversation, Message, NativeRoom, Participant}

  def audience(%Conversation{native_access_scope: :agent_peer, origin_conversation_id: id}) do
    case id && Conversations.get_conversation!(id) do
      %Conversation{} = origin -> audience(origin)
      _ -> []
    end
  end

  def audience(%Conversation{native_access_scope: :anchor_page, page_id: id}) do
    Principals.list_principals!(query: [filter: [type: :human, status: :active]])
    |> Enum.filter(&page_visible?(&1, id))
    |> Enum.map(& &1.uid)
  end

  def audience(%Conversation{kind: :native, id: id}) do
    uids =
      NativeRoom.participants(id)
      |> Enum.reject(&(&1.role in [:agent, :observer]))
      |> Enum.map(& &1.principal_uid)

    Principals.list_principals!(query: [filter: [uid: [in: uids], type: :human, status: :active]])
    |> Enum.map(& &1.uid)
  end

  def audience(%Conversation{kind: :external} = conversation),
    do: Ankole.Brain.external_audience(conversation)

  def audience(_), do: []

  def index(run) do
    with %Conversation{} = current <- current(run),
         %{type: :ai_colleague} <- Principals.get_agent_record!(run.agent_uid),
         [_ | _] = people <- audience(current) do
      candidates(run.agent_uid, current.id, people)
      |> Stream.filter(&allowed?(&1, run.agent_uid, people))
      |> Enum.take(8)
      |> Enum.map(&summary/1)
    else
      _ -> []
    end
  end

  @inline_token_budget 180

  def inline(run) do
    run
    |> index()
    |> select_core_entries()
    |> enrich_entries(:meta)
    |> enrich_entries(:pages)
    |> render_entries()
  end

  defp select_core_entries(items) do
    items
    |> Enum.reduce([], fn item, rev_kept ->
      title = clean_title(item.title)

      Enum.find_value([24, 12], rev_kept, fn limit ->
        candidate = [%{item: item, title: title, line: core_line(item, title, limit)} | rev_kept]
        if within_budget?(Enum.reverse(candidate)), do: candidate
      end)
    end)
    |> Enum.reverse()
  end

  defp enrich_entries(entries, stage) do
    Enum.reduce(Enum.with_index(entries), entries, fn {entry, idx}, current ->
      Enum.find_value(stage_candidates(entry, stage), current, fn line ->
        updated = List.replace_at(current, idx, %{entry | line: line})
        if within_budget?(updated), do: updated
      end)
    end)
  end

  defp stage_candidates(%{item: item, title: title}, :meta),
    do: [meta_line(item, title, count_pages(item.page_ids))]

  defp stage_candidates(%{item: %{page_ids: []}}, :pages), do: []

  defp stage_candidates(%{item: item, title: title}, :pages) do
    ids = item.page_ids
    total = length(ids)
    full = meta_line(item, title, "pages=" <> Enum.join(ids, ","))

    prefixes =
      if total > 1 do
        for count <- min(total - 1, 6)..1//-1 do
          shown = Enum.take(ids, count)
          meta_line(item, title, "pages=#{Enum.join(shown, ",")},+#{total - count}")
        end
      else
        []
      end

    [full | prefixes]
  end

  defp core_line(item, title, limit),
    do: "#{item.ref_id} | #{item.kind} | #{String.slice(title, 0, limit)}"

  defp meta_line(item, title, ""),
    do:
      "#{item.ref_id} | #{item.kind} | #{compact_time(item.updated_at)} | #{item.status} | #{title}"

  defp meta_line(item, title, pages),
    do: "#{meta_line(item, title, "")} | #{pages}"

  defp count_pages([]), do: ""
  defp count_pages(ids), do: "pages=#{length(ids)}"

  defp clean_title(raw) do
    case raw |> to_string() |> String.replace(~r/[\s|]+/u, " ") |> String.trim() do
      "" -> "-"
      cleaned -> String.slice(cleaned, 0, 40)
    end
  end

  defp compact_time(iso8601), do: String.replace(iso8601, ~r/\.\d+Z$/, "Z")

  defp within_budget?(entries),
    do: Ankole.Kernel.estimate_o200k_base_tokens(render_entries(entries)) <= @inline_token_budget

  defp render_entries([]), do: ""
  defp render_entries(entries), do: Enum.map_join(entries, "\n", & &1.line) <> "\n"

  def recall(run, id, cursor) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Conversation{} = current <- current(run),
         %Conversation{} = item <- Conversations.get_conversation!(id),
         true <- allowed?(item, run.agent_uid, audience(current)) do
      read(item, run.agent_uid, cursor)
    else
      _ -> {:error, :related_context_unavailable}
    end
  end

  defp current(run) do
    if run.event.conversation_id do
      Conversations.get_conversation!(run.event.conversation_id)
    else
      case run.session_id && Ankole.Conversations.Route.long_lived_source(run) do
        {:ok, %{reply_route: %{"conversation_id" => id}}} when is_binary(id) ->
          Conversations.get_conversation!(id)

        _ ->
          nil
      end
    end
  end

  defp candidates(uid, current_id, people) do
    query =
      Conversation
      |> Ash.Query.filter(
        kind == :native and id != ^current_id and
          exists(
            Participant,
            conversation_id == parent(id) and principal_uid == ^uid and role == :agent
          )
      )
      |> Ash.Query.sort(last_activity_at: :desc, id: :desc)
      |> Ash.Query.limit(100)

    query =
      Enum.reduce(people, query, fn human, query ->
        Ash.Query.filter(
          query,
          native_access_scope == :anchor_page or
            exists(
              Participant,
              conversation_id == parent(id) and principal_uid == ^human and
                role in [:owner, :member]
            ) or
            exists(
              Participant,
              conversation_id == parent(origin_conversation_id) and principal_uid == ^human and
                role in [:owner, :member]
            )
        )
      end)

    Stream.unfold(nil, fn
      :done ->
        nil

      cursor ->
        rows = query |> older_than(cursor) |> Ankole.Ash.read!()

        case rows do
          [] -> nil
          rows -> {rows, if(length(rows) == 100, do: List.last(rows), else: :done)}
        end
    end)
    |> Stream.flat_map(& &1)
  end

  defp older_than(query, nil), do: query

  defp older_than(query, %{id: id, last_activity_at: activity}),
    do:
      Ash.Query.filter(
        query,
        last_activity_at < ^activity or (last_activity_at == ^activity and id < ^id)
      )

  defp allowed?(item, uid, people) do
    member = NativeRoom.participant(item.id, uid)

    people != [] and match?(%{role: :agent}, member) and
      MapSet.subset?(MapSet.new(people), MapSet.new(audience(item))) and
      Enum.all?(page_ids(item), &page_visible?(Principals.get_principal_record!(uid), &1))
  end

  defp page_visible?(principal, id),
    do:
      match?(
        {:ok, _},
        Ankole.Pod.authorize_node(Ankole.AuthZ.Actor.new(principal), id, "node_view")
      )

  defp summary(item) do
    members = NativeRoom.agents(item.id)
    keys = Enum.map(members, &{&1.uid, Ankole.Sessions.Key.conversation(item.id)})
    statuses = Ankole.Sessions.statuses(keys)

    %{
      status:
        if(Enum.any?(statuses, fn {_, status} -> status.state != :idle end),
          do: "active",
          else: "idle"
        ),
      ref_id: item.id,
      kind: item.native_access_scope,
      updated_at: DateTime.to_iso8601(item.last_activity_at),
      page_ids: page_ids(item),
      title: String.slice(item.title, 0, 40)
    }
  end

  defp page_ids(%{native_access_scope: :agent_peer, id: id}) do
    case Message
         |> Ash.Query.filter(conversation_id == ^id and links != [] and not withdrawn)
         |> Ash.Query.sort(seq: :desc)
         |> Ash.Query.limit(1)
         |> Ankole.Ash.read_one!() do
      nil -> []
      message -> for %{"kind" => "page", "id" => page_id} <- message.links, do: page_id
    end
  end

  defp page_ids(item), do: List.wrap(item.page_id)

  defp read(%{native_access_scope: :anchor_page, page_id: id}, uid, cursor) do
    Ankole.Pod.Comments.list(Ankole.AuthZ.Actor.new(Principals.get_principal_record!(uid)), id, %{
      status: :all,
      cursor: cursor,
      limit: 20
    })
  end

  defp read(item, _uid, cursor) do
    with {after_seq, ""} <- Integer.parse(cursor || "0") do
      rows =
        Message
        |> Ash.Query.filter(conversation_id == ^item.id and seq > ^after_seq and not withdrawn)
        |> Ash.Query.sort(seq: :asc)
        |> Ash.Query.limit(51)
        |> Ankole.Ash.read!()

      messages = Enum.take(rows, 50)

      {:ok,
       %{
         ref_id: item.id,
         messages:
           Enum.map(messages, &Map.take(&1, [:seq, :author_uid, :text, :links, :created_at])),
         next_cursor: if(length(rows) > 50, do: to_string(List.last(messages).seq))
       }}
    else
      _ -> {:error, :invalid_cursor}
    end
  end
end
