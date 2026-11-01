defmodule Ankole.Files.NodeContents do
  @moduledoc "Commits a file node's current immutable object under its write authority."

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Files.{Access, Nodes, Objects, Paths}
  alias Ankole.Files.Schemas.Node
  alias Ankole.Repo

  def write(actor, id, content) do
    with {:ok, actor} <- actor(actor),
         {:ok, node} <- Nodes.fetch(id),
         :ok <- authorize_write(actor, node),
         {:ok, object} <- Objects.store(content) do
      # Moving an ACL-anchor ancestor need not lock this file row. Keep the
      # topology stable while resolving its current root and committing bytes.
      Access.write(actor.turn_authority, fn -> commit_in_tx(actor, id, object) end,
        shared_tree: true,
        root_ids: fn -> Nodes.root_ids([id]) end,
        after_commit: &Nodes.content_committed/1
      )
    end
  end

  def commit_in_tx(actor, id, stored, attrs \\ %{}) do
    require_transaction!(:commit_in_tx)

    with {:ok, actor} <- actor(actor),
         {:ok, node} <- Nodes.lock(id),
         :ok <- authorize_write(actor, node),
         {:ok, object} <- Objects.complete_in_tx(stored),
         {:ok, updated} <-
           Ankole.Ash.update(
             node,
             :update_in_tx,
             Map.merge(Map.take(attrs, [:mode, :content_type, :source]), %{
               object_id: object.id,
               updated_at: DateTime.utc_now(:microsecond)
             })
           ) do
      {:ok, Paths.project(updated, object, updated.name)}
    end
  end

  def authorize_write(_actor, %{deleted_at: deleted_at, purge_started_at: purge_started_at})
      when not is_nil(deleted_at) or not is_nil(purge_started_at),
      do: {:error, :not_found}

  def authorize_write(actor, %{kind: :file, object_id: nil, parent_id: parent_id}) do
    with {:ok, _} <- Nodes.authorize(actor, parent_id, "node_contribute") do
      :ok
    end
  end

  def authorize_write(actor, %{kind: :file, id: id}) do
    with {:ok, _} <- Nodes.authorize(actor, id, "node_edit"), do: :ok
  end

  def authorize_write(_actor, _node), do: {:error, :not_a_file}

  def create_conversation_file_in_tx(conversation_id, name, stored, attrs \\ %{}) do
    require_transaction!(:create_conversation_file_in_tx)

    with {:ok, root} <- Nodes.ensure_conversation_root_in_tx(conversation_id),
         {:ok, object} <- Objects.complete_in_tx(stored) do
      case existing_conversation_file(root, object.id) do
        nil -> create_file(root, name, object, Map.put_new(attrs, :source, "inbound"))
        node -> {:ok, Paths.project(node, object, node.name)}
      end
    end
  end

  def create_private_file_in_tx(uid, name, stored, attrs \\ %{}) do
    require_transaction!(:create_private_file_in_tx)

    with {:ok, root} <- Nodes.ensure_private_root_in_tx(uid),
         :ok <- Paths.lock_root(root.id),
         {:ok, object} <- Objects.complete_in_tx(stored) do
      create_file(root, name, object, Map.put_new(attrs, :source, "generated"))
    end
  end

  defp create_file(root, name, object, attrs) do
    attrs =
      attrs
      |> Map.take([:mode, :content_type, :source, :message_id, :created_by])
      |> Map.merge(%{
        parent_id: root.id,
        name: Ankole.Files.Path.file_name(name),
        kind: :file,
        object_id: object.id
      })

    with {:ok, node} <- Nodes.create_in_tx(attrs),
         do: {:ok, Paths.project(node, object, node.name)}
  end

  defp existing_conversation_file(root, object_id) do
    Node
    |> Ash.Query.filter(object_id == ^object_id and is_nil(deleted_at))
    |> Ankole.Ash.read!()
    |> Enum.find(fn node -> Nodes.conversation_id(node.id) == {:ok, root.conversation_id} end)
  end

  def actor(%Actor{} = actor), do: {:ok, actor}

  def actor(uid) when is_binary(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         do: {:ok, Actor.new(principal)}
  end

  defp require_transaction!(operation) do
    unless Repo.in_transaction?(),
      do: raise(Ankole.Errors.Framework.TransactionRequired, operation: {__MODULE__, operation})
  end
end
