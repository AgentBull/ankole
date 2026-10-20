defmodule Ankole.Sessions.Events do
  @moduledoc "Publishes Session input hints, committed state changes, and transient activity."

  alias Ankole.Repo

  def subscribe(agent_uid, session_id),
    do: Phoenix.PubSub.subscribe(Ankole.PubSub, topic(agent_uid, session_id, :state))

  def unsubscribe(agent_uid, session_id),
    do: Phoenix.PubSub.unsubscribe(Ankole.PubSub, topic(agent_uid, session_id, :state))

  def subscribe_input(agent_uid, session_id),
    do: Phoenix.PubSub.subscribe(Ankole.PubSub, topic(agent_uid, session_id, :input))

  @doc "Hints that an accepted Signal is ready. The Driver reads its durable inbox."
  def publish_input(agent_uid, session_id, signal_id) do
    Repo.assert_outside_transaction!()

    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      topic(agent_uid, session_id, :input),
      {:inbox, signal_id}
    )
  end

  def publish_status(agent_uid, session_id) do
    Repo.assert_outside_transaction!()
    broadcast(agent_uid, session_id, :status)
  end

  def publish_turn_completed(agent_uid, session_id, signal_id, outcome) do
    Repo.assert_outside_transaction!()
    broadcast(agent_uid, session_id, {:turn_completed, signal_id, outcome})
  end

  @doc "Publishes a transient Driver snapshot. This event does not establish a durable fact."
  def publish_activity(agent_uid, session_id, snapshot),
    do: broadcast(agent_uid, session_id, {:activity, self(), snapshot})

  defp broadcast(agent_uid, session_id, event) do
    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      topic(agent_uid, session_id, :state),
      {:session_event, agent_uid, session_id, event}
    )
  end

  defp topic(agent_uid, session_id, kind) do
    agent = Base.url_encode64(agent_uid, padding: false)
    session = Base.url_encode64(session_id, padding: false)
    "session:#{Repo.tenant_id!()}:#{agent}:#{kind}:#{session}"
  end
end
