defmodule Ankole.Pod.Documents.Insights do
  @moduledoc "Document readership and daily activity, committed alongside their owning operation."
  require Ash.Query
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Files.Access
  alias Ankole.Pod.{PageDailyActivity, Pages, PageUserState, Serialization}

  @session_seconds 300

  def read(actor, id) do
    Repo.transact_top_level(fn ->
      with {:ok, %{page: page, content: content}} <- Pages.get_in_tx(actor, id),
           :ok <- document(page) do
        authors = Enum.uniq([page.created_by, content.updated_by | content.contributors])
        profiles = Serialization.author_profiles(authors)
        first_day = Date.add(Date.utc_today(), -29)

        daily =
          PageDailyActivity
          |> Ash.Query.filter(page_id == ^id and day >= ^first_day)
          |> Ash.Query.sort(day: :asc)
          |> Ankole.Ash.read!()

        state = user_state_in_tx(AuthZ.Actor.uid(actor), id)

        {:ok,
         %{
           created_at: page.created_at,
           updated_at: page.updated_at,
           contributors: Enum.map(authors, &contributor(&1, page, content, profiles)),
           daily: Enum.map(daily, &Map.take(&1, [:day, :views, :edits, :comments])),
           can_view_readers: match?({:ok, _}, Access.authorize(actor, page, "node_edit")),
           hide_visits: (state && state.hide_visits) || false
         }}
      end
    end)
  end

  def viewers(actor, id, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(id, :share),
           {:ok, _} <- Access.authorize(actor, page, "node_edit"),
           :ok <- document(page) do
        query =
          PageUserState
          |> Ash.Query.for_read(:viewers)
          |> Ash.Query.filter(page_id == ^id and not is_nil(visited_at) and not hide_visits)
          |> Ash.Query.sort(visited_at: :desc, principal_uid: :asc)

        limit = Ankole.Attrs.get(opts, :limit, 25)
        cursor = Ankole.Attrs.get(opts, :cursor)
        pagination = if cursor, do: [limit: limit, after: cursor], else: [limit: limit]

        with {:ok, result} <- Ankole.Ash.read(query, page: pagination) do
          profiles = Serialization.author_profiles(Enum.map(result.results, &viewer_actor/1))

          {:ok,
           %{
             total: Ankole.Ash.count!(query),
             viewers:
               Enum.map(result.results, fn state ->
                 %{
                   person: Serialization.author_json(viewer_actor(state), profiles),
                   visited_at: state.visited_at
                 }
               end),
             next_cursor: if(result.more?, do: List.last(result.results).__metadata__.keyset)
           }}
        end
      end
    end)
  end

  defp viewer_actor(state),
    do: Ankole.ActorRef.from_principal(%{tenant_id: state.tenant_id, uid: state.principal_uid})

  def visit_in_tx(_page, _uid, nil), do: :ok

  def visit_in_tx(%{type: :doc, id: id}, uid, now) do
    previous = user_state_in_tx(uid, id)
    if due?(previous && previous.visited_at, now), do: record_in_tx(id, :views, now), else: :ok
  end

  def visit_in_tx(_page, _uid, _now), do: :ok

  def edit_in_tx(id, uid, now) do
    previous = user_state_in_tx(uid, id)

    with :ok <-
           if(due?(previous && previous.edited_at, now),
             do: record_in_tx(id, :edits, now),
             else: :ok
           ),
         {:ok, _} <- Pages.save_state_in_tx(uid, id, %{edited_at: now}),
         do: :ok
  end

  @doc "The caller holds the page update lock; counters share its transaction."
  def record_in_tx(id, kind, now) when kind in [:views, :edits, :comments] do
    day = DateTime.to_date(now)

    previous =
      PageDailyActivity
      |> Ash.Query.filter(page_id == ^id and day == ^day)
      |> Ankole.Ash.read_one!()

    count = if previous, do: Map.fetch!(previous, kind), else: 0

    with {:ok, _} <-
           Ankole.Ash.create(
             PageDailyActivity,
             :put,
             Map.put(%{page_id: id, day: day}, kind, count + 1),
             upsert_fields: [kind]
           ),
         do: :ok
  end

  defp user_state_in_tx(uid, id),
    do:
      PageUserState
      |> Ash.Query.filter(page_id == ^id and principal_uid == ^uid)
      |> Ankole.Ash.read_one!()

  defp due?(nil, _now), do: true
  defp due?(previous, now), do: DateTime.diff(now, previous, :second) >= @session_seconds
  defp document(%{type: :doc}), do: :ok
  defp document(_), do: {:error, :invalid_page_type}

  defp contributor(author, page, content, profiles) do
    role =
      cond do
        author == page.created_by -> :creator
        author == content.updated_by -> :last_edited
        true -> :previously_edited
      end

    Map.put(Serialization.author_json(author, profiles), :role, role)
  end
end
