defmodule Ankole.Files.Vfs.Namespace do
  @moduledoc "Resolves the canonical Drive projection through its existing ACL graph."
  require Ash.Query
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Files.Schemas.Node
  alias Ankole.Kernel

  def roots(scope) do
    asker = scope.context.disclosure.asker_uid

    [
      {"Public", Nodes.public_root()},
      {"AgentDrive", Nodes.private_root(scope.actor.principal.uid)},
      {"MyDrive",
       if(asker && asker != scope.actor.principal.uid,
         do: Nodes.private_root(asker),
         else: {:error, :not_found}
       )},
      {"ChatDrive",
       if(scope.conversation_id,
         do: Nodes.conversation_root(scope.conversation_id),
         else: {:error, :not_found}
       )}
    ]
    |> Enum.flat_map(fn
      {name, {:ok, node}} ->
        if visible?(scope, node), do: [%{node: node, kind: :folder, name: name}], else: []

      _ ->
        []
    end)
  end

  def resolve(_scope, []), do: {:ok, %{node: nil, kind: :root, name: ""}}

  def resolve(scope, [root | rest]) do
    case Enum.find(roots(scope), &(&1.name == root)) do
      nil -> {:error, :not_found}
      entry -> descend(scope, entry, rest)
    end
  end

  def children(scope, %{kind: :root}), do: {:ok, roots(scope)}
  def children(scope, %{kind: :base} = entry), do: Ankole.Files.Vfs.Base.children(scope, entry)
  def children(scope, %{base_path: _} = entry), do: Ankole.Files.Vfs.Base.children(scope, entry)

  def children(scope, %{kind: :applet} = entry),
    do: Ankole.Files.Vfs.Applet.children(scope, entry)

  def children(scope, %{applet_path: _} = entry),
    do: Ankole.Files.Vfs.Applet.children(scope, entry)

  def children(scope, %{kind: kind, node: node}) when kind in [:folder, :children] do
    policy = Ankole.AuthZ.Checks.DriveAnchorFilter.policy(scope.access.reachable)

    entries =
      Node
      |> Ash.Query.filter(parent_id == ^node.id and ^policy.filter)
      |> Ash.Query.sort(name: :asc)
      |> Ankole.Ash.read!()

    child_parents = entries |> Enum.filter(&(&1.kind in [:doc, :knowledge])) |> Enum.map(& &1.id)

    with_children =
      Node
      |> Ash.Query.filter(parent_id in ^child_parents and ^policy.filter)
      |> Ash.Query.select([:parent_id])
      |> Ankole.Ash.read!()
      |> MapSet.new(& &1.parent_id)

    {:ok,
     Enum.flat_map(entries, fn child ->
       primary = entry(child, child.kind)

       if MapSet.member?(with_children, child.id),
         do: [primary, entry(child, :children)],
         else: [primary]
     end)}
  end

  def children(_scope, _entry), do: {:error, :not_a_directory}

  def authorize(scope, node, action) do
    if visible?(scope, node),
      do: Access.authorize_reachable(node, action, scope.access.reachable, trash: false),
      else: {:error, :not_found}
  end

  def entry(node, kind),
    do: %{node: node, kind: kind, name: Kernel.vfs_name(node.name, kind, node.id)}

  def collection?(%{kind: kind}),
    do: kind in [:root, :folder, :children, :base, :applet, :virtual_directory]

  defp descend(_scope, entry, []), do: {:ok, entry}

  defp descend(scope, %{kind: :base, node: node}, parts),
    do: Ankole.Files.Vfs.Base.resolve(scope, node, parts)

  defp descend(scope, %{kind: :applet, node: node}, parts),
    do: Ankole.Files.Vfs.Applet.resolve(scope, node, parts)

  defp descend(scope, %{kind: kind, node: node}, [segment | rest])
       when kind in [:folder, :children] do
    with {:ok, child} <- find_child(node.id, segment),
         {:ok, _} <- authorize(scope, child.node, "node_view"),
         do: descend(scope, child, rest)
  end

  defp descend(_scope, _entry, _rest), do: {:error, :not_found}

  defp find_child(parent_id, segment) do
    decoded = Kernel.vfs_decode_name(segment)

    candidate =
      case decoded do
        {name, kind} when is_binary(name) ->
          case Nodes.child(parent_id, name) do
            {:ok, node} -> match_entry(node, segment, kind)
            _ -> nil
          end

        _ ->
          nil
      end

    if candidate do
      {:ok, candidate}
    else
      # Shortened names carry an identity digest. Re-encoding verifies both the
      # digest and prefix, including names that end in an escaped digest marker.
      found =
        if String.contains?(segment, "~"),
          do:
            Nodes.list_children(parent_id)
            |> Enum.find_value(fn node -> match_entry(node, segment, nil) end)

      if found, do: {:ok, found}, else: {:error, :not_found}
    end
  end

  defp match_entry(node, segment, _kind) do
    kinds = if node.kind in [:doc, :knowledge], do: [node.kind, :children], else: [node.kind]

    Enum.find_value(kinds, fn kind ->
      candidate = entry(node, kind)
      if candidate.name == segment, do: candidate
    end)
  end

  defp visible?(scope, node),
    do:
      match?(
        {:ok, _},
        Access.authorize_reachable(node, "node_view", scope.access.reachable, trash: false)
      )
end
