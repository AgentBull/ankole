defmodule Ankole.Pod.AgentUI do
  @moduledoc """
  Owns the requests that Agents send to a Human's open Pod tabs: opening one,
  handing it to exactly one tab, storing the tab's answer, and expiring a
  request that no tab finished. `Ankole.Pod.AgentUIRequest` keeps them.
  """

  require Ash.Query
  alias Ankole.Pod.AgentUIRequest

  @doc "The PubSub topic that reaches every open Pod tab of one Human."
  def topic(tenant_id, uid), do: "agent-ui:#{tenant_id}:#{uid}"

  @doc "Commits a request inside the caller's transaction."
  def open_in_tx(attrs), do: Ankole.Ash.create(AgentUIRequest, :open_in_tx, attrs)

  @doc "Pushes a committed request to the Human's open Pod tabs."
  def publish(%AgentUIRequest{} = request) do
    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      topic(Ankole.Repo.tenant_id!(), request.principal_uid),
      {:agent_ui_request, request.id}
    )
  end

  def get(id), do: Ankole.Ash.read_one(Ash.Query.filter(AgentUIRequest, id == ^id))

  @doc "The Human's requests that still wait for a tab, oldest first, opened at or after `since`."
  def pending(uid, since) do
    AgentUIRequest
    |> Ash.Query.filter(principal_uid == ^uid and status == :pending and inserted_at >= ^since)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ankole.Ash.read!()
  end

  @doc "One of the Human's requests while it still waits for a tab."
  def pending_one(uid, id) do
    AgentUIRequest
    |> Ash.Query.filter(id == ^id and principal_uid == ^uid and status == :pending)
    |> Ankole.Ash.read_one()
  end

  @doc "Hands a pending request to the Human's tab that asks first."
  def claim(uid, id) do
    case change(uid, id, :pending, :claim, %{}) do
      {:ok, [_claimed]} -> :ok
      _not_claimed -> {:error, if(match?({:ok, %{}}, own(uid, id)), do: :taken, else: :not_found)}
    end
  end

  @doc "Stores the claiming tab's answer: `%{status: :done, result: ...}` or `%{status: :failed, error: ...}`."
  def answer(uid, id, answer) do
    case change(uid, id, :claimed, :finish, answer) do
      {:ok, [_finished]} -> :ok
      _other -> {:error, :not_found}
    end
  end

  @doc "Expires a request that no tab finished in time and gives its latest state."
  def expire(id) do
    case Ankole.Ash.update_where(Ash.Query.filter(AgentUIRequest, id == ^id), :expire, %{}) do
      {:ok, [expired]} -> {:ok, expired}
      # A tab answered between the caller's read and this write, so its answer stands.
      _raced -> get(id)
    end
  end

  defp own(uid, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         do:
           Ankole.Ash.read_one(
             Ash.Query.filter(AgentUIRequest, id == ^id and principal_uid == ^uid)
           )
  end

  # A tab may send an id that is not a UUID, which matches no request.
  defp change(uid, id, status, action, input) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      AgentUIRequest
      |> Ash.Query.filter(id == ^id and principal_uid == ^uid and status == ^status)
      |> Ankole.Ash.update_where(action, input)
    end
  end
end
