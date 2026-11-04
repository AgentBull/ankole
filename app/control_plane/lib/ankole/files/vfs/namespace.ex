defmodule Ankole.Files.Vfs.Namespace do
  @moduledoc "Resolves the canonical Drive projection from Pages and their ACL graph."
  require Ash.Expr
  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Tree, as: Nodes
  alias Ankole.Pod.Pages
  alias Ankole.Kernel

  def roots(%{library_only: true} = scope), do: Ankole.Files.Vfs.Library.roots(scope)

  def roots(scope), do: page_roots(scope) ++ Ankole.Files.Vfs.Library.roots(scope)

  defp page_roots(%{library_only: true}), do: []

  defp page_roots(scope) do
    asker = scope.context.disclosure.asker_uid

    [
      {"Public", Nodes.public_root()},
      {"Brain", Nodes.system_node("ankole_brain")},
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
        if visible?(scope, node),
          do: [%{node: node, kind: :folder, name: name, read_only: name == "Brain"}],
          else: []

      _ ->
        []
    end)
  end

  def resolve(scope, path), do: resolve(scope, path, false)
  def resolve_write(scope, path), do: resolve(scope, path, true)

  defp resolve(_scope, [], _body), do: {:ok, %{node: nil, kind: :root, name: ""}}

  defp resolve(scope, [root | _] = path, _body) when root in ["Skills", "AGENTS.md", "DESIGN.md"],
    do: Ankole.Files.Vfs.Library.resolve(scope, path)

  defp resolve(scope, [root | rest], body) do
    case Enum.find(page_roots(scope), &(&1.name == root)) do
      nil ->
        {:error, :not_found}

      entry ->
        with {:ok, result} <- descend(scope, entry, rest, body),
             do: {:ok, Map.put(result, :read_only, Map.get(entry, :read_only, false))}
    end
  end

  def children(scope, %{library_path: _} = entry),
    do: Ankole.Files.Vfs.Library.children(scope, entry)

  def children(scope, entry) do
    with {:ok, children} <- children_entry(scope, entry),
         do:
           {:ok,
            Enum.map(children, &Map.put_new(&1, :read_only, Map.get(entry, :read_only, false)))}
  end

  defp children_entry(scope, %{kind: :root}), do: {:ok, roots(scope)}

  defp children_entry(scope, %{kind: :base} = entry),
    do: Ankole.Files.Vfs.Base.children(scope, entry)

  defp children_entry(scope, %{base_path: _} = entry),
    do: Ankole.Files.Vfs.Base.children(scope, entry)

  defp children_entry(scope, %{kind: :applet} = entry),
    do: Ankole.Files.Vfs.Applet.children(scope, entry)

  defp children_entry(scope, %{applet_path: _} = entry),
    do: Ankole.Files.Vfs.Applet.children(scope, entry)

  defp children_entry(scope, %{kind: kind, node: node}) when kind in [:folder, :children] do
    policy = Ankole.AuthZ.Checks.PageAnchorFilter.policy(page_access(scope, node).reachable)

    entries =
      Ankole.Pod.list_page_records!(
        query: [
          filter:
            Ash.Expr.expr(
              parent_id == ^node.id and
                (is_nil(system_key) or system_key != "ankole_brain_sources") and ^policy.filter
            ),
          sort: [name: :asc]
        ]
      )

    child_parents = entries |> Enum.filter(&(&1.type in [:doc, :knowledge])) |> Enum.map(& &1.id)

    with_children =
      Ankole.Pod.list_page_records!(
        query: [
          filter: Ash.Expr.expr(parent_id in ^child_parents and ^policy.filter),
          select: [:parent_id]
        ]
      )
      |> MapSet.new(& &1.parent_id)

    {:ok,
     Enum.flat_map(entries, fn child ->
       cond do
         node.system_key == "ankole_brain" ->
           [%{node: child, kind: :folder, name: child.name}]

         child.type in [:doc, :knowledge] and Pages.content_empty?(child) ->
           [entry(child, :children)]

         MapSet.member?(with_children, child.id) ->
           [entry(child, child.type), entry(child, :children)]

         true ->
           [entry(child, child.type)]
       end
     end)}
  end

  defp children_entry(_scope, _entry), do: {:error, :not_a_directory}

  def authorize(scope, node, action) do
    if visible?(scope, node),
      do:
        Access.authorize_reachable(node, action, page_access(scope, node).reachable, trash: false),
      else: {:error, :not_found}
  end

  def entry(node, kind),
    do: %{node: node, kind: kind, name: Kernel.vfs_name(node.name, kind, node.id)}

  def collection?(%{kind: kind}),
    do: kind in [:root, :folder, :children, :base, :applet, :virtual_directory]

  defp descend(_scope, entry, [], _body), do: {:ok, entry}

  defp descend(scope, %{kind: :base, node: node}, parts, _body),
    do: Ankole.Files.Vfs.Base.resolve(scope, node, parts)

  defp descend(scope, %{kind: :applet, node: node}, parts, _body),
    do: Ankole.Files.Vfs.Applet.resolve(scope, node, parts)

  defp descend(scope, %{node: %{system_key: "ankole_brain", id: id}}, [name | rest], body) do
    with {:ok, child} <- Nodes.child(id, name),
         true <- child.system_key != "ankole_brain_sources",
         {:ok, _} <- authorize(scope, child, "node_view"),
         do: descend(scope, %{node: child, kind: :folder, name: name}, rest, body),
         else: (
           false -> {:error, :not_found}
           error -> error
         )
  end

  defp descend(scope, %{kind: kind, node: node}, [segment | rest], body)
       when kind in [:folder, :children] do
    with {:ok, child} <- find_child(node.id, segment, body),
         {:ok, _} <- authorize(scope, child.node, "node_view"),
         do: descend(scope, child, rest, body)
  end

  defp descend(_scope, _entry, _rest, _body), do: {:error, :not_found}

  defp find_child(parent_id, segment, body) do
    decoded = Kernel.vfs_decode_name(segment)

    candidate =
      case decoded do
        {name, _kind} when is_binary(name) ->
          case Nodes.child(parent_id, name) do
            {:ok, node} -> match_entry(node, segment, body)
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
            |> Enum.find_value(fn node -> match_entry(node, segment, body) end)

      if found, do: {:ok, found}, else: {:error, :not_found}
    end
  end

  defp match_entry(node, segment, body) do
    kinds =
      if node.type in [:doc, :knowledge] do
        if body or not Pages.content_empty?(node), do: [node.type, :children], else: [:children]
      else
        [node.type]
      end

    Enum.find_value(kinds, fn kind ->
      candidate = entry(node, kind)
      if candidate.name == segment, do: candidate
    end)
  end

  defp page_access(scope, node) do
    if Access.brain_page?(node), do: scope.brain_access, else: scope.access
  end

  defp visible?(scope, node),
    do:
      match?(
        {:ok, _},
        Access.authorize_reachable(node, "node_view", page_access(scope, node).reachable,
          trash: false
        )
      )
end
