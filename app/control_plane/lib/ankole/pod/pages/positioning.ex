defmodule Ankole.Pod.Pages.Positioning do
  @moduledoc "Maintains fractional sibling ordering across Pod Page directories under the tree lock."
  require Ash.Query

  alias Ankole.Pod.{Page, Position}

  def initial_in_tx(parent_id, attrs) do
    case Ankole.Attrs.get(attrs, :position) do
      nil ->
        if is_nil(Ankole.Attrs.get(attrs, :after_id)) and
             is_nil(Ankole.Attrs.get(attrs, :before_id)) do
          {:ok, nil}
        else
          with :ok <- materialize_in_tx(parent_id),
               do: move_in_tx(%{id: nil}, parent_id, nil, attrs)
        end

      position ->
        {:ok, position}
    end
  end

  def materialize_in_tx(parent_id) do
    siblings = siblings(parent_id, nil, nil)

    if Enum.any?(siblings, &is_nil(&1.position)) do
      siblings
      |> Enum.zip(Position.sequence(length(siblings)))
      |> Enum.reduce_while(:ok, fn {sibling, position}, :ok ->
        case Ankole.Ash.update(sibling, :position, %{position: position}) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  def previous_location(page) do
    location = Map.take(page, [:parent_id, :private_owner_uid])

    siblings = siblings(page.parent_id, page.private_owner_uid, nil)
    index = Enum.find_index(siblings, &(&1.id == page.id))
    next = index && Enum.at(siblings, index + 1)
    previous = if index && index > 0, do: Enum.at(siblings, index - 1)

    cond do
      next -> Map.put(location, :before_id, next.id)
      previous -> Map.put(location, :after_id, previous.id)
      true -> location
    end
  end

  # One anchor names the sibling next to the moved page. Without an anchor the
  # page goes last. An anchor outside the destination is a stale view.
  def move_in_tx(page, parent, owner, attrs) do
    after_id = Ankole.Attrs.get(attrs, :after_id)
    before_id = Ankole.Attrs.get(attrs, :before_id)

    if is_nil(after_id) and is_nil(before_id) do
      {:ok, next_position(parent, owner)}
    else
      siblings = siblings(parent, owner, page.id)
      anchor = Enum.find_index(siblings, &(&1.id in [after_id, before_id]))

      cond do
        after_id && before_id -> {:error, :invalid_position}
        is_nil(anchor) -> {:error, :position_conflict}
        after_id -> place(siblings, anchor + 1)
        true -> place(siblings, anchor)
      end
    end
  end

  defp next_position(parent, owner) do
    last = Page |> in_destination(parent, owner) |> Ankole.Ash.max!(:position)

    case Position.between(last, nil) do
      {:ok, position} -> position
      :error -> last <> "V"
    end
  end

  defp place(siblings, index) do
    lower = if index > 0, do: Enum.at(siblings, index - 1).position
    upper = if upper = Enum.at(siblings, index), do: upper.position

    case Position.between(lower, upper) do
      {:ok, position} -> {:ok, position}
      :error -> renumber(siblings, index)
    end
  end

  # Equal or foreign keys have no key between them. Renumber the destination,
  # which is already serialized by the tree lock.
  defp renumber(siblings, index) do
    {before, rest} = Enum.split(siblings, index)
    keys = Position.sequence(length(siblings) + 1)

    (before ++ [:moved] ++ rest)
    |> Enum.zip(keys)
    |> Enum.reduce({:ok, nil}, fn
      {:moved, key}, {:ok, _} ->
        {:ok, key}

      {sibling, key}, result ->
        {:ok, _} = Ankole.Ash.update(sibling, :position, %{position: key})
        result
    end)
  end

  defp siblings(parent, owner, moving_id) do
    query = Ash.Query.filter(Page, is_nil(deleted_at))
    query = if moving_id, do: Ash.Query.filter(query, id != ^moving_id), else: query

    query
    |> in_destination(parent, owner)
    |> Ash.Query.sort(position: :asc_nils_last, name: :asc, id: :asc)
    |> Ankole.Ash.read!()
  end

  defp in_destination(query, parent, owner) do
    query =
      if parent,
        do: Ash.Query.filter(query, parent_id == ^parent),
        else: Ash.Query.filter(query, is_nil(parent_id))

    if owner,
      do: Ash.Query.filter(query, private_owner_uid == ^owner),
      else: Ash.Query.filter(query, is_nil(private_owner_uid))
  end
end
