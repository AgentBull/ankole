defmodule Ankole.Pod.Pages.RecentSearches do
  @moduledoc """
  Persists per-principal recent search queries in a Pod (`pod_search_queries`),
  coalescing incremental prefix keystrokes within a 30-second window and bounding
  history to the newest 20 queries per principal.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.{SearchProjection, SearchQuery}
  alias Ankole.Repo

  @default_limit 8
  @max_history 20
  @max_query_chars 120
  @coalesce_window_seconds 30

  @spec list(Actor.t(), integer() | nil) :: {:ok, [map()]}
  def list(%Actor{} = actor, limit \\ @default_limit) do
    clamped =
      if is_integer(limit),
        do: max(1, min(limit, @max_history)),
        else: @default_limit

    Repo.transact_repeatable_read_only(fn ->
      uid = Actor.uid(actor)

      rows =
        SearchQuery
        |> Ash.Query.filter(principal_uid == ^uid)
        |> Ash.Query.sort(updated_at: :desc, id: :desc)
        |> Ash.Query.limit(clamped)
        |> Ankole.Ash.read!()

      {:ok, Enum.map(rows, &serialize/1)}
    end)
  end

  @spec record(Actor.t(), String.t(), integer() | nil) :: {:ok, map() | nil} | {:error, term()}
  def record(actor, query, result_count \\ 0)

  def record(%Actor{} = actor, query, result_count) when is_binary(query) do
    clean =
      query
      |> SearchProjection.sanitize()
      |> String.trim()
      |> String.slice(0, @max_query_chars)

    count = if is_integer(result_count) and result_count >= 0, do: result_count, else: 0

    if String.length(clean) < 2 do
      {:ok, nil}
    else
      Repo.transact_top_level(fn ->
        uid = Actor.uid(actor)
        now = DateTime.utc_now(:microsecond)

        exact =
          SearchQuery
          |> Ash.Query.filter(principal_uid == ^uid and query == ^clean)
          |> Ankole.Ash.read_one!()

        latest =
          SearchQuery
          |> Ash.Query.filter(principal_uid == ^uid)
          |> Ash.Query.sort(updated_at: :desc, id: :desc)
          |> Ash.Query.limit(1)
          |> Ankole.Ash.read_one!()

        saved =
          cond do
            exact != nil ->
              if latest != nil and latest.id != exact.id and within_coalesce_window?(latest, now) and
                   prefix_related?(latest.query, clean) do
                {:ok, _} = Ankole.Ash.destroy(latest, :remove)
              end

              {:ok, updated} =
                Ankole.Ash.update(exact, :replace, %{
                  query: clean,
                  result_count: count,
                  updated_at: now
                })

              updated

            latest != nil and within_coalesce_window?(latest, now) and
                prefix_related?(latest.query, clean) ->
              {:ok, updated} =
                Ankole.Ash.update(latest, :replace, %{
                  query: clean,
                  result_count: count,
                  updated_at: now
                })

              updated

            true ->
              Ankole.Ash.create!(SearchQuery, :put, %{
                principal_uid: uid,
                query: clean,
                result_count: count,
                updated_at: now
              })
          end

        prune_overflow_in_tx(uid)
        {:ok, serialize(saved)}
      end)
    end
  end

  def record(_actor, _query, _result_count), do: {:error, :invalid_request}

  @spec delete(Actor.t(), String.t()) :: {:ok, %{deleted: boolean()}} | {:error, :invalid_request}
  def delete(%Actor{} = actor, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.transact_top_level(fn ->
          uid = Actor.uid(actor)

          {:ok, _} =
            SearchQuery
            |> Ash.Query.filter(principal_uid == ^uid and id == ^uuid)
            |> Ankole.Ash.destroy_where(:remove)

          {:ok, %{deleted: true}}
        end)

      :error ->
        {:error, :invalid_request}
    end
  end

  def delete(_actor, _id), do: {:error, :invalid_request}

  @spec clear(Actor.t()) :: {:ok, %{cleared: boolean()}}
  def clear(%Actor{} = actor) do
    Repo.transact_top_level(fn ->
      uid = Actor.uid(actor)

      {:ok, _} =
        SearchQuery
        |> Ash.Query.filter(principal_uid == ^uid)
        |> Ankole.Ash.destroy_where(:remove)

      {:ok, %{cleared: true}}
    end)
  end

  defp within_coalesce_window?(%SearchQuery{updated_at: updated_at}, now) do
    diff = DateTime.diff(now, updated_at, :second)
    diff >= 0 and diff <= @coalesce_window_seconds
  end

  defp prefix_related?(previous, current) do
    left = String.downcase(previous)
    right = String.downcase(current)
    String.starts_with?(right, left) or String.starts_with?(left, right)
  end

  defp prune_overflow_in_tx(uid) do
    stale_ids =
      SearchQuery
      |> Ash.Query.filter(principal_uid == ^uid)
      |> Ash.Query.sort(updated_at: :desc, id: :desc)
      |> Ash.Query.offset(@max_history)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)

    if stale_ids != [] do
      {:ok, _} =
        SearchQuery
        |> Ash.Query.filter(principal_uid == ^uid and id in ^stale_ids)
        |> Ankole.Ash.destroy_where(:remove)
    end

    :ok
  end

  defp serialize(%SearchQuery{} = row) do
    %{
      id: row.id,
      query: row.query,
      result_count: row.result_count,
      updated_at: row.updated_at
    }
  end
end
