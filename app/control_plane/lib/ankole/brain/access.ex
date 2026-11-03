defmodule Ankole.Brain.Access do
  @moduledoc "Page visibility shared by knowledge, claims and their disclosure readers."
  import Bitwise
  require Ash.Query
  alias Ankole.Pod.Access.Graph

  defstruct querier_uid: nil, reachable: %{}, containers: [], pages: []
  @type t :: %__MODULE__{}
  @type disclosure :: %{
          mode: :strict | :relaxed,
          asker_uid: String.t() | nil,
          present_uids: [String.t()]
        }

  def open_disclosure, do: %{mode: :relaxed, asker_uid: nil, present_uids: []}
  def for_querier(uid), do: for_readers(uid, open_disclosure())
  def for_readers(uid, disclosure), do: for_context(%{querier_uid: uid, disclosure: disclosure})

  def for_context(%{querier_uid: uid} = context) do
    with {:ok, reachable} <- visibility(context) do
      {containers, pages} = Graph.visibility_ids(reachable)

      {:ok,
       %__MODULE__{querier_uid: uid, reachable: reachable, containers: containers, pages: pages}}
    end
  end

  def visibility(context, opts \\ [])

  def visibility(%__MODULE__{reachable: reachable}, _opts), do: {:ok, reachable}

  def visibility(%{querier_uid: uid, disclosure: disclosure} = context, opts) do
    recipients = recipients(disclosure)
    authn = Map.get(context, :authn, %{})

    if disclosure.mode == :strict and recipients == [] do
      {:ok, %{}}
    else
      [uid | recipients]
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, nil}, fn reader, {:ok, accumulated} ->
        with {:ok, principal} <- Ankole.Principals.get_principal(reader),
             {:ok, reachable} <-
               Graph.reachable_anchors(Ankole.AuthZ.Actor.new(principal, authn: authn), opts) do
          {:cont, {:ok, intersect_reachable(accumulated, reachable)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def visible_node?(%__MODULE__{reachable: reachable}, node),
    do: is_nil(node.deleted_at) and band(Graph.page_bits(node, reachable), 1) == 1

  def visible_node?(context, node) do
    case for_context(context) do
      {:ok, access} -> visible_node?(access, node)
      {:error, _} -> false
    end
  end

  def visible?(access, id) do
    case Ankole.Pod.Pages.Tree.fetch(id) do
      {:ok, node} -> visible_node?(access, node)
      {:error, _} -> false
    end
  end

  def filter_objects(%Ash.Query{} = query, access) do
    Ash.Query.filter(
      query,
      ^Ankole.AuthZ.Checks.PageAnchorFilter.policy(access.reachable).filter
    )
  end

  def filter_claims(%Ash.Query{} = query, access) do
    Ash.Query.filter(
      query,
      live_parent? and
        exists(
          source_node,
          is_nil(deleted_at) and
            ((not is_acl_anchor and acl_anchor_id in ^access.containers) or
               (is_acl_anchor and id in ^access.pages))
        )
    )
  end

  def filter_chunks(%Ash.Query{} = query, access) do
    Ash.Query.filter(
      query,
      exists(
        source_node,
        is_nil(deleted_at) and
          ((not is_acl_anchor and acl_anchor_id in ^access.containers) or
             (is_acl_anchor and id in ^access.pages))
      )
    )
  end

  def filter_timelines(query, access) do
    Ash.Query.filter(
      query,
      exists(
        source_node,
        is_nil(deleted_at) and
          ((not is_acl_anchor and acl_anchor_id in ^access.containers) or
             (is_acl_anchor and id in ^access.pages))
      )
    )
  end

  def filter_links(%Ash.Query{} = query, access) do
    Ash.Query.filter(
      query,
      exists(
        from_page,
        is_nil(deleted_at) and
          ((not is_acl_anchor and acl_anchor_id in ^access.containers) or
             (is_acl_anchor and id in ^access.pages))
      ) and
        exists(
          to_page,
          is_nil(deleted_at) and
            ((not is_acl_anchor and acl_anchor_id in ^access.containers) or
               (is_acl_anchor and id in ^access.pages))
        )
    )
  end

  def filter_current_claims(query), do: Ash.Query.filter(query, current? == true)

  def disclosable?(source_node_id, disclosure) do
    case {disclosure.mode, recipients(disclosure)} do
      {:relaxed, []} ->
        true

      {:strict, []} ->
        false

      {_, readers} ->
        Enum.all?(readers, fn uid ->
          case for_querier(uid) do
            {:ok, access} -> visible?(access, source_node_id)
            {:error, _} -> false
          end
        end)
    end
  end

  def filter_disclosable(rows, source_fun, disclosure) do
    case {disclosure.mode, recipients(disclosure)} do
      {:relaxed, []} ->
        rows

      {:strict, []} ->
        []

      {_, readers} ->
        contexts = Enum.map(readers, &for_querier/1)
        ids = rows |> Enum.map(source_fun) |> Enum.uniq()

        visible =
          Ankole.Pod.Page
          |> Ash.Query.filter(id in ^ids and is_nil(deleted_at))
          |> Ash.Query.select([:acl_anchor_id, :is_acl_anchor, :deleted_at])
          |> Ankole.Ash.read!()
          |> Enum.filter(fn page ->
            Enum.all?(contexts, fn
              {:ok, access} -> visible_node?(access, page)
              {:error, _} -> false
            end)
          end)
          |> MapSet.new(& &1.id)

        Enum.filter(rows, &MapSet.member?(visible, source_fun.(&1)))
    end
  end

  defp intersect_reachable(nil, right), do: right

  defp intersect_reachable(left, right) do
    Map.new(left, fn {id, bits} ->
      other = Map.get(right, id, %{self_bits: 0, container_bits: 0})

      {id,
       %{
         self_bits: band(bits.self_bits, other.self_bits),
         container_bits: band(bits.container_bits, other.container_bits)
       }}
    end)
  end

  defp recipients(%{mode: :strict} = disclosure),
    do: Enum.uniq(List.wrap(disclosure[:asker_uid]) ++ (disclosure[:present_uids] || []))

  defp recipients(disclosure), do: List.wrap(disclosure[:asker_uid])
end
