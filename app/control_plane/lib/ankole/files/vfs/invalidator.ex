defmodule Ankole.Files.Vfs.Invalidator do
  @moduledoc "Projects committed Drive changes onto the existing Worker control channel."
  alias Ankole.RuntimeFabric.V1, as: Proto

  def subscribe do
    tenant = Ankole.Repo.tenant_id!()
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-content:" <> tenant)
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-vfs-access:" <> tenant)
  end

  def envelope(ids, all?) do
    %Proto.Envelope{
      message_id: "vfs-" <> Ecto.UUID.generate(),
      body:
        {:vfs_invalidate, %Proto.VfsInvalidate{node_ids: MapSet.to_list(ids), all_clean: all?}}
    }
  end
end
