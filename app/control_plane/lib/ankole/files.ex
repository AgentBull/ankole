defmodule Ankole.Files do
  @moduledoc "Owns Drive nodes, their access rules, immutable tenant objects and collection."
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Files.{Objects, Paths, NodeContents, Nodes}

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      route(Ankole.Files.ConsoleOperations, :get, "/drive/:tenant_id/nodes", :console_list,
        name: "list_drive_nodes"
      )

      route(Ankole.Files.ConsoleOperations, :post, "/drive/:tenant_id/nodes", :console_create,
        name: "create_drive_node"
      )

      route(Ankole.Files.ConsoleOperations, :patch, "/drive/:tenant_id/nodes/:id", :console_move,
        name: "move_drive_node"
      )

      route(
        Ankole.Files.ConsoleOperations,
        :delete,
        "/drive/:tenant_id/nodes/:id",
        :console_delete,
        name: "delete_drive_node"
      )
    end
  end

  resources do
    resource(Ankole.Files.ConsoleOperations)
    resource(Ankole.Files.Schemas.Node)
    resource(Ankole.Files.Schemas.FileObject)
  end

  defdelegate store(content), to: Objects
  defdelegate upload_limit(), to: Objects
  defdelegate complete_object_in_tx(stored), to: Objects, as: :complete_in_tx
  defdelegate fetch_object(id), to: Objects, as: :fetch
  defdelegate read_object(id), to: Objects, as: :read
  defdelegate read_object_to_file(id, path), to: Objects, as: :read_to_file
  defdelegate read_object_range(id, offset, length), to: Objects, as: :read_range
  defdelegate collect_objects(), to: Objects, as: :collect
  defdelegate enqueue_tenant_object_deletions_in_tx(), to: Objects

  @doc "The durable foreign keys that keep immutable objects alive."
  def object_references,
    do: [
      {"drive_nodes", "object_id"},
      {"message_attachments", "object_id"},
      {"delivery_attachments", "object_id"},
      {"pod_files", "object_id"}
    ]

  defdelegate node_committed(node), to: Nodes, as: :content_committed
  defdelegate broadcast_node(id), to: Nodes, as: :broadcast
  defdelegate fetch_node(id), to: Nodes, as: :fetch
  defdelegate lock_tree_in_tx(), to: Nodes, as: :lock_tree
  defdelegate lock_root_ids_in_tx(ids), to: Nodes, as: :lock_roots
  defdelegate root_ids_for_principal(uid), to: Nodes
  defdelegate delete_private_root_in_tx(uid), to: Nodes
  defdelegate delete_conversation_root_in_tx(id), to: Nodes
  defdelegate root(id), to: Nodes
  defdelegate root_ids(ids), to: Nodes
  defdelegate private_root(uid), to: Nodes
  defdelegate public_root(), to: Nodes
  defdelegate conversation_root(id), to: Nodes
  defdelegate ensure_private_root_in_tx(uid), to: Nodes
  defdelegate ensure_public_root_in_tx(), to: Nodes
  defdelegate ensure_conversation_root_in_tx(id), to: Nodes
  defdelegate visible_node_ids(reachable, ids \\ nil, bit \\ 1), to: Nodes, as: :visible_ids
  defdelegate ancestor_node_ids(ids), to: Nodes, as: :ancestor_ids
  defdelegate descendant_node_ids(id), to: Nodes, as: :descendants
  defdelegate shared_root_node_ids(ids, reachable), to: Nodes, as: :shared_root_ids
  defdelegate acl_anchor_nodes(), to: Nodes, as: :anchor_nodes
  defdelegate hidden_trashed_node_ids(), to: Nodes, as: :hidden_trashed_ids
  defdelegate authorize_node(actor, id, action), to: Nodes, as: :authorize
  defdelegate node_conversation_id(id), to: Nodes, as: :conversation_id
  defdelegate create_node(actor, attrs), to: Nodes, as: :create
  defdelegate move_node(actor, id, attrs), to: Nodes, as: :move
  defdelegate rename_node(actor, id, name), to: Nodes, as: :rename
  def rename_node_in_tx(actor, id, name), do: Nodes.move_in_tx(actor, id, %{name: name})
  defdelegate trash_node(actor, id), to: Nodes, as: :trash
  defdelegate restore_node(actor, id), to: Nodes, as: :restore
  defdelegate write_node(actor, id, content), to: NodeContents, as: :write

  defdelegate authorize_node_write(actor, node), to: NodeContents, as: :authorize_write

  defdelegate commit_node_object_in_tx(actor, id, object, attrs \\ %{}),
    to: NodeContents,
    as: :commit_in_tx

  defdelegate create_conversation_file_in_tx(conversation_id, name, object, attrs \\ %{}),
    to: NodeContents

  defdelegate create_private_file_in_tx(agent_uid, name, object, attrs \\ %{}),
    to: NodeContents

  # Agent runtime files use paths relative to their existing private root.
  # These functions address the same Drive nodes used by the node-ID API.
  defdelegate fetch(agent_uid, path), to: Paths
  defdelegate fetch_many(agent_uid, paths), to: Paths
  defdelegate list_under_prefixes(agent_uid, paths), to: Paths
  defdelegate read(agent_uid, path), to: Paths
  defdelegate read_to_file(agent_uid, path, local_path), to: Paths
  defdelegate list(agent_uid, prefix \\ "", opts \\ []), to: Paths
  defdelegate list_snapshot_in_tx(agent_uid, prefix, opts), to: Paths
  defdelegate commit(agent_uid, upserts, deletes \\ []), to: Paths
  defdelegate commit_in_tx(agent_uid, upserts, deletes \\ []), to: Paths
  defdelegate move(agent_uid, from, to), to: Paths
  defdelegate move_in_tx(agent_uid, from, to), to: Paths
  defdelegate delete(agent_uid, path), to: Paths
  defdelegate delete_in_tx(agent_uid, path), to: Paths
  defdelegate lock_drive(agent_uid), to: Paths

  defdelegate console_download(actor, tenant_id, id),
    to: Ankole.Files.ConsoleActions,
    as: :download

  defdelegate console_upload(actor, tenant_id, parent_id, name, local_path, content_type),
    to: Ankole.Files.ConsoleActions,
    as: :upload

  defdelegate normalize_path(path), to: Ankole.Files.Path, as: :normalize
  defdelegate normalize_existing_path(path), to: Ankole.Files.Path, as: :normalize_existing
  defdelegate file_name(name), to: Ankole.Files.Path, as: :file_name
  defdelegate sanitize_display_path(path), to: Ankole.Files.Path, as: :sanitize_display_path

  @doc "Returns a unique local transfer path. The caller removes it after use."
  def temp_path do
    dir = Path.join(System.tmp_dir!(), "ankole-files")
    File.mkdir_p!(dir)
    Path.join(dir, Ecto.UUID.generate())
  end
end
