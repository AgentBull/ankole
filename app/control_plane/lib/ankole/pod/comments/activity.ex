defmodule Ankole.Pod.Comments.Activity do
  @moduledoc "Orders discussion activity and stores each reader's explicit acknowledgment."
  require Ash.Query
  alias Ankole.{ActorRef, AuthZ, Repo}
  alias Ankole.Pod.{Access, PageComment, PageContent, Pages, PageUserState}

  def summary(actor, id) do
    Repo.transact_top_level(fn ->
      with {:ok, %{type: :doc} = page} <- Pages.lock(id, :share),
           {:ok, _} <- Access.authorize(actor, page, "page_view") do
        {:ok, summary_in_tx(actor, id)}
      else
        {:ok, _} -> {:error, :invalid_page_type}
        error -> error
      end
    end)
  end

  def acknowledge(actor, id, through) do
    Repo.transact_top_level(
      fn ->
        with {:ok, %{type: :doc} = page} <- Pages.lock(id),
             {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_view") do
          latest = Ankole.Ash.max!(roots_in_tx(id), :activity_at)
          previous = read_at_in_tx(actor, id)

          read_at =
            if latest && DateTime.compare(through, latest) == :gt, do: latest, else: through

          if latest && (is_nil(previous) || DateTime.compare(read_at, previous) == :gt) do
            {:ok, _} =
              Pages.save_state_in_tx(AuthZ.Actor.uid(actor), id, %{comments_read_at: read_at})
          end

          {:ok, summary_in_tx(actor, id)}
        else
          {:ok, _} -> {:error, :invalid_page_type}
          error -> error
        end
      end,
      after_commit: fn _ ->
        Phoenix.PubSub.broadcast(
          Ankole.PubSub,
          "pod-page:" <> id,
          {:comments_read, AuthZ.Actor.uid(actor)}
        )
      end
    )
  end

  def read_at_in_tx(actor, id) do
    uid = AuthZ.Actor.uid(actor)

    case PageUserState
         |> Ash.Query.filter(page_id == ^id and principal_uid == ^uid)
         |> Ankole.Ash.read_one!() do
      nil -> nil
      state -> state.comments_read_at
    end
  end

  def unread_query_in_tx(query, actor, id) do
    author = ActorRef.from_actor(actor)
    query = Ash.Query.filter(query, activity_by != ^author)

    case read_at_in_tx(actor, id) do
      nil -> query
      read_at -> Ash.Query.filter(query, activity_at > ^read_at)
    end
  end

  def roots_in_tx(id) do
    PageComment
    |> Ash.Query.filter(
      page_id == ^id and is_nil(root_id) and
        (is_nil(deleted_at) or exists(replies, is_nil(deleted_at)))
    )
  end

  def touch_in_tx(actor, id, comment) do
    root_id = comment.root_id || comment.id

    root =
      PageComment
      |> Ash.Query.filter(page_id == ^id and id == ^root_id)
      |> Ankole.Ash.read_one!(not_found_error?: true)

    Ankole.Ash.update(root, :activity_in_tx, %{
      activity_at: DateTime.utc_now(:microsecond),
      activity_by: ActorRef.from_actor(actor)
    })
  end

  def unread?(root, actor, read_at) do
    root.activity_by.uid != AuthZ.Actor.uid(actor) &&
      (is_nil(read_at) || DateTime.compare(root.activity_at, read_at) == :gt)
  end

  defp summary_in_tx(actor, id) do
    roots = roots_in_tx(id)
    content = PageContent |> Ash.Query.filter(page_id == ^id) |> Ankole.Ash.read_one!()
    {:ok, info} = Ankole.Kernel.page_comment_info(content.content)

    resolved_ids =
      roots
      |> Ash.Query.filter(id in ^info.ids and not is_nil(resolved_at))
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)

    %{
      resolved_ids: resolved_ids,
      unread_count: roots |> unread_query_in_tx(actor, id) |> Ankole.Ash.count!(),
      open_count: roots |> Ash.Query.filter(is_nil(resolved_at)) |> Ankole.Ash.count!(),
      activity_at: Ankole.Ash.max!(roots, :activity_at)
    }
  end
end
