defmodule Ankole.Brain.Scope do
  @moduledoc "Source nodes and deterministic Principal knowledge paths."
  alias Ankole.Pod.Pages.Tree, as: Nodes

  def principal_page_slug(:human, uid), do: "people/" <> uid
  def principal_page_slug(:agent, uid), do: "agents/" <> uid

  def parse_principal_page_slug(slug) do
    case String.split(slug, "/", parts: 2) do
      ["people", uid] -> {:ok, {:human, uid}}
      ["agents", uid] -> {:ok, {:agent, uid}}
      _ -> :error
    end
  end

  def canonical_slug(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         do: {:ok, principal_page_slug(principal.type, uid)}
  end

  def canonical_page_id(uid) do
    with {:ok, path} <- canonical_slug(uid),
         {:ok, page} <- Ankole.Brain.Objects.get_by_slug(path),
         do: {:ok, page.id}
  end

  def principal(uid) do
    case Nodes.private_root(Ankole.Principals.authority_uid(uid)) do
      {:ok, node} -> node.id
      {:error, _} -> nil
    end
  end

  def conversation(id) do
    with {:ok, node} <- Nodes.conversation_root(id), do: {:ok, node.id}
  end

  def world do
    with {:ok, node} <- Ankole.Brain.Namespace.root(), do: node.id
  end

  def parse(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_source_node_id}
    end
  end

  def validate(id) do
    with {:ok, node} <- Nodes.fetch(id),
         true <- is_nil(node.deleted_at),
         do: :ok,
         else: (_ -> {:error, :invalid_source_node_id})
  end

  def validate_writable(id, uid) do
    with {:ok, _} <- Nodes.authorize(uid, id, "node_view"), do: :ok
  end

  def satisfied_by?(id, uid) do
    with {:ok, access} <- Ankole.Brain.Access.for_querier(uid),
         do: Ankole.Brain.Access.visible?(access, id),
         else: (_ -> false)
  end

  def satisfied_by_all?(id, uids), do: Enum.all?(uids, &satisfied_by?(id, &1))
end
