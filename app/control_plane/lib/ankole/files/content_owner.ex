defmodule Ankole.Files.ContentOwner do
  @moduledoc """
  Application-owned work that Drive delegates around a node's lifecycle and content.

  Drive calls the configured owner before it removes nodes, after it renames
  one, after it names a new object at a file node, and before it hands a file
  node's bytes to a reader, so that content kept outside the object (such as
  a spreadsheet's pending edits) stays consistent with it.
  """
  @callback purge_nodes([Ecto.UUID.t()]) :: :ok | {:error, term()}

  @callback purge_nodes_in_tx([Ecto.UUID.t()]) :: :ok | {:error, term()}

  @callback rename_node_in_tx(struct(), struct(), Ankole.AuthZ.Actor.t()) ::
              :ok | {:error, term()}

  @doc """
  Runs in the writer's transaction after `node` takes a new object; `previous`
  is the node before the write.
  """
  @callback object_committed_in_tx(struct(), struct(), Ankole.AuthZ.Actor.t()) ::
              :ok | {:error, term()}

  @doc """
  Writes pending edits into a file node's object before Drive reads it. Runs
  outside a transaction.
  """
  @callback flush_node(Ecto.UUID.t()) :: :ok | {:error, term()}

  def rename_node_in_tx(old, node, actor) do
    owner = Application.fetch_env!(:ankole, __MODULE__)
    owner.rename_node_in_tx(old, node, actor)
  end

  def object_committed_in_tx(previous, node, actor) do
    owner = Application.fetch_env!(:ankole, __MODULE__)
    owner.object_committed_in_tx(previous, node, actor)
  end

  def flush_node(id) do
    owner = Application.fetch_env!(:ankole, __MODULE__)
    owner.flush_node(id)
  end

  def purge_nodes_in_tx(ids) do
    owner = Application.fetch_env!(:ankole, __MODULE__)
    owner.purge_nodes_in_tx(ids)
  end

  def purge_nodes(ids) do
    owner = Application.fetch_env!(:ankole, __MODULE__)
    owner.purge_nodes(ids)
  end
end
