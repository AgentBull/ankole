defmodule Ankole.Files do
  @moduledoc "Owns immutable tenant objects and the Drive projection of Pages."
  defdelegate upload_http(actor, file_ref, method, url, headers, opts \\ []),
    to: Ankole.Files.HTTP,
    as: :upload

  defdelegate download_http(actor, url, headers, destination, opts \\ []),
    to: Ankole.Files.HTTP,
    as: :download

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Files.Objects
  alias Ankole.Files.Paths

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
    resource(Ankole.Files.Schemas.FileObject)
    resource(Ankole.Files.Schemas.VfsExport)
  end

  defdelegate store(content), to: Objects

  defdelegate validate_image_source(source, content_type, max_bytes),
    to: Ankole.Files.ImageSignature,
    as: :validate_source

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
      {"pages", "object_id"},
      {"skill_files", "object_id"},
      {"message_attachments", "object_id"},
      {"delivery_attachments", "object_id"},
      {"pod_files", "object_id"},
      {"drive_vfs_exports", "object_id"},
      {"page_snapshots", "object_id"},
      {"profile_avatars", "object_id"},
      {"ai_gateway_media_jobs", "object_id"}
    ]

  # Agent runtime files use paths relative to their existing private root.
  # These functions address the same Drive nodes used by the node-ID API.
  defdelegate fetch(agent_uid, path), to: Paths
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
  defdelegate file_name(name), to: Ankole.Files.Path, as: :file_name
  defdelegate sanitize_display_path(path), to: Ankole.Files.Path, as: :sanitize_display_path

  @doc "Returns a unique local transfer path. The caller removes it after use."
  def temp_path do
    dir = Path.join(System.tmp_dir!(), "ankole-files")
    File.mkdir_p!(dir)
    Path.join(dir, Ecto.UUID.generate())
  end
end
