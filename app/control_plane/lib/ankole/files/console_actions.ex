defmodule Ankole.Files.ConsoleActions do
  @moduledoc "Browses and manages tenant Drive nodes independently of Worker availability."
  use Ash.Resource.Actions.Implementation
  require Ash.Expr
  require Ash.Query
  alias Ankole.{Errors, Files, Repo, Tenants}
  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Tree, as: Nodes
  alias Ankole.Files.Objects
  alias Ankole.Pod.Page, as: Node

  def download(actor, tenant_id, id),
    do: authorized(actor, :console_download, %{tenant_id: tenant_id, id: id})

  def upload(actor, tenant_id, parent_id, name, local_path, content_type),
    do:
      authorized(actor, :console_upload, %{
        tenant_id: tenant_id,
        parent_id: parent_id,
        name: name,
        local_path: local_path,
        content_type: content_type
      })

  defp authorized(actor, action, args) do
    Files.ConsoleOperations
    |> Ash.ActionInput.for_action(action, args)
    |> Ankole.Ash.run_action_authorized(actor)
    |> Errors.reason()
  end

  @impl true
  def run(input, _opts, context) do
    result =
      with {:ok, actor} <- Access.admin_actor(context.actor, operation(input.action.name)),
           {:ok, %Tenants.Tenant{}} <- Tenants.get_tenant(input.arguments.tenant_id) do
        Repo.with_tenant(input.arguments.tenant_id, fn ->
          execute(input.action.name, input.arguments, actor)
        end)
      else
        {:ok, nil} -> {:error, :not_found}
        error -> error
      end

    Errors.wrap(result, &describe/1)
  end

  defp operation(name) when name in [:console_list, :console_download], do: "read"
  defp operation(:console_delete), do: "delete"
  defp operation(_), do: "update"

  defp execute(:console_list, attrs, actor) do
    attrs = Map.merge(%{parent_id: nil, owner_uid: nil, relative_path: nil, after: nil}, attrs)

    with {:ok, parent_id} <- selected_parent(attrs),
         :ok <- authorize_parent(actor, parent_id),
         attrs = Map.put(attrs, :parent_id, parent_id),
         {:ok, ancestors} <- ancestors(attrs.parent_id),
         {:ok, cursor} <- decode_cursor(attrs.after) do
      filter = Ash.Expr.expr(is_nil(deleted_at))

      filter =
        if attrs.parent_id,
          do: Ash.Expr.expr(^filter and parent_id == ^attrs.parent_id),
          else: Ash.Expr.expr(^filter and is_nil(parent_id))

      filter =
        case cursor do
          nil -> filter
          {name, id} -> Ash.Expr.expr(^filter and (name > ^name or (name == ^name and id > ^id)))
        end

      nodes =
        Ankole.Pod.list_page_records!(
          query: [filter: filter, sort: [name: :asc, id: :asc], limit: attrs.limit + 1]
        )

      page = Enum.take(nodes, attrs.limit)
      cursor = if length(nodes) > attrs.limit, do: encode_cursor(List.last(page))
      object_ids = page |> Enum.map(& &1.object_id) |> Enum.reject(&is_nil/1)

      sizes =
        Ankole.Files.Schemas.FileObject
        |> Ash.Query.filter(id in ^object_ids)
        |> Ash.Query.select([:size])
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1.size})

      {:ok,
       %{
         nodes: Enum.map(page, &node_json(&1, Map.get(sizes, &1.object_id, 0))),
         ancestors: ancestors,
         next_after: cursor
       }}
    end
  end

  defp execute(:console_create, attrs, actor) do
    with {:ok, parent} <- Nodes.fetch(attrs.parent_id),
         type = attrs[:kind] || if(parent.type == :knowledge, do: :knowledge, else: :doc),
         {:ok, node} <- Nodes.create(actor, %{parent_id: parent.id, name: attrs.name, type: type}),
         do: {:ok, %{id: node.id}}
  end

  defp execute(:console_move, attrs, actor) do
    changes =
      attrs |> Map.take([:parent_id, :name]) |> Map.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, node} <- Nodes.move(actor, attrs.id, changes), do: {:ok, %{id: node.id}}
  end

  defp execute(:console_delete, attrs, actor) do
    with {:ok, node} <- Nodes.trash(actor, attrs.id), do: {:ok, %{id: node.id}}
  end

  defp execute(:console_download, attrs, actor) do
    with {:ok, %{type: :file} = node} <- Nodes.authorize(actor, attrs.id, "node_view"),
         {:ok, object} <- download_object(node.object_id),
         do: {:ok, %{node: Map.take(node, [:name, :content_type]), object: object}},
         else: (
           {:ok, _} -> {:error, :not_found}
           error -> error
         )
  end

  defp execute(:console_upload, attrs, actor) do
    with {:ok, stored} <- Objects.store({:file, attrs.local_path}) do
      result =
        Access.write_tree(
          nil,
          fn ->
            with {:ok, parent} <- Nodes.fetch(attrs.parent_id),
                 {:ok, _} <- Nodes.authorize_child_create(actor, parent),
                 {:ok, object} <- Objects.complete_in_tx(stored) do
              Nodes.create_in_tx(%{
                parent_id: parent.id,
                name: attrs.name,
                type: :file,
                object_id: object.id,
                source: "console",
                content_type: attrs.content_type,
                created_by: Ankole.ActorRef.from_actor(actor)
              })
            end
          end,
          root_ids: fn -> Nodes.root_ids([attrs.parent_id]) end,
          after_commit: fn _ -> Access.broadcast_change() end
        )

      with {:ok, node} <- result, do: {:ok, node_json(node)}
    end
  end

  defp download_object(nil), do: {:ok, nil}
  defp download_object(id), do: Objects.fetch(id)

  defp authorize_parent(_actor, nil), do: :ok

  defp authorize_parent(actor, id) do
    with {:ok, _} <- Nodes.authorize(actor, id, "node_view"), do: :ok
  end

  # The owner's private root is the base directory; an omitted path opens the root itself.
  defp selected_parent(%{parent_id: nil, owner_uid: uid, relative_path: path})
       when is_binary(uid) do
    with {:ok, root} <- Nodes.private_root(uid),
         {:ok, node} <- Files.Paths.resolve(root, path || ""),
         do: {:ok, node.id}
  end

  defp selected_parent(attrs), do: {:ok, attrs.parent_id}

  defp ancestors(nil), do: {:ok, []}

  defp ancestors(id) do
    with {:ok, node} <- Nodes.fetch(id),
         {:ok, nodes} <- Nodes.path(node),
         do: {:ok, Enum.map(nodes, &Map.take(&1, [:id, :name]))}
  end

  @doc false
  def node_json(node) do
    object =
      case Objects.fetch(node.object_id) do
        {:ok, object} -> object
        _ -> nil
      end

    node_json(node, if(object, do: object.size, else: 0))
  end

  defp node_json(node, size) do
    %{
      id: node.id,
      parent_id: node.parent_id,
      name: node.name,
      kind: to_string(node.type),
      object_id: node.object_id,
      private_owner_uid: node.private_owner_uid,
      conversation_id: node.conversation_id,
      size: size,
      content_type: node.content_type,
      updated_at: DateTime.to_iso8601(node.updated_at)
    }
  end

  defp encode_cursor(node),
    do: [node.name, node.id] |> Torque.encode!() |> Base.url_encode64(padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [name, id]} when is_binary(name) <- Torque.decode(json),
         {:ok, id} <- Ecto.UUID.cast(id),
         do: {:ok, {name, id}},
         else: (_ -> {:error, :invalid_cursor})
  end

  defp describe(:not_found), do: Errors.Invalid.NotFound.exception(resource: Node)
  defp describe(:invalid_cursor), do: {"The directory cursor is invalid", []}
  defp describe(:invalid_name), do: {"The node name contains invalid characters", []}
  defp describe(_), do: nil
end
