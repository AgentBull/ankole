defmodule Ankole.Files.ContentOwner do
  @moduledoc "Application-owned cleanup performed before Drive removes nodes."
  @callback purge_nodes([Ecto.UUID.t()]) :: :ok | {:error, term()}

  @callback purge_nodes_in_tx([Ecto.UUID.t()]) :: :ok | {:error, term()}

  @callback rename_node_in_tx(struct(), struct(), Ankole.AuthZ.Actor.t()) ::
              :ok | {:error, term()}

  def rename_node_in_tx(old, node, actor) do
    owner = Application.fetch_env!(:ankole, __MODULE__)
    owner.rename_node_in_tx(old, node, actor)
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
